import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:bhe_core/bhe_core.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'features/video_source/project_paths.dart';
import 'features/video_source/project_file_commit.dart';
import 'features/video_source/video_source_store.dart';
import 'features/video_source/video_source_failure.dart';
import 'media_bridge.dart';
import 'native_analysis_engine.dart';

class MobileAppState extends ChangeNotifier {
  MobileAppState({
    MobileAnalysisEngine? analysisEngine,
    VideoSourceStore? videoSourceStore,
    this.videoProbe,
  }) : analysisEngine = analysisEngine ?? NativeAnalysisEngine(),
       _providedVideoStore = videoSourceStore {
    ready = Future.wait([loadSavedProject(), _loadPlayerGroups()]).then((_) {});
  }

  late final Future<void> ready;
  final VideoSourceStore? _providedVideoStore;
  final Future<VideoInfo> Function(File)? videoProbe;
  late final VideoSourceStore _videoStore =
      _providedVideoStore ??
      VideoSourceStore(
        dataDirectory: _dataDirectory,
        temporaryDirectory: () async =>
            Directory((await getTemporaryDirectory()).path),
      );

  static const playerGroupsPrefsKey = 'bhe.player_groups';

  final MobileAnalysisEngine analysisEngine;
  final MobileExportEngine exportEngine = NativeMediaExportEngine();

  ProjectSnapshot project = ProjectSnapshot(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    name: '新项目',
    video: null,
  );
  List<ProjectSnapshot> recentProjects = const [];
  List<({String name, List<String> players})> playerGroups = const [];

  /// Cover image per project id, taken from a shot frame after analysis.
  Map<String, String> coverPaths = const {};
  AnalysisStage stage = AnalysisStage.idle;
  double progress = 0;
  String progressMessage = '';
  int? processedFrames;
  int? totalFrames;
  Duration? eta;
  String? errorMessage;
  VideoSourceFailure? videoSourceFailure;
  int videoSourceRevision = 0;
  bool get videoMissing => videoSourceFailure == VideoSourceFailure.missing;
  bool get canRelinkVideo => videoSourceFailure?.canRelink ?? false;
  bool relinkingVideo = false;
  bool relinkCancelling = false;
  int _relinkSerial = 0;
  bool _disposed = false;

  void markVideoFailure(VideoSourceFailure failure) {
    if (_disposed) return;
    videoSourceFailure = failure;
    errorMessage = failure.message;
    notifyListeners();
  }

  void _recordVideoFailure(Object error, String? path) {
    markVideoFailure(
      error is VideoSourceMismatch
          ? VideoSourceFailure.mismatch
          : path != null && !File(path).existsSync()
          ? VideoSourceFailure.missing
          : VideoSourceFailure.unplayable,
    );
  }

  void cancelVideoPreparation() {
    if (!preparingVideo) return;
    _invalidateVideoPreparation();
    notifyListeners();
  }

  void cancelVideoRelink() {
    if (!relinkingVideo || relinkCancelling) return;
    _videoPreparationGeneration++;
    relinkCancelling = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _videoPreparationGeneration++;
    super.dispose();
  }

  bool loading = true;
  bool preparingVideo = false;
  String preparingVideoMessage = '';
  bool analysing = false;
  bool exporting = false;
  bool exportCancelled = false;
  bool exportAudioSkipped = false;
  List<String> exportedPaths = const [];
  Future<void> _saveChain = Future<void>.value();
  int _analysisGeneration = 0;
  int _videoPreparationGeneration = 0;
  DateTime? analysisStartedAt;

  bool get hasVideo => project.video != null;
  bool get sourceVideoExists =>
      project.video != null && File(project.video!.path).existsSync();
  Duration get analysisElapsed => analysisStartedAt == null
      ? Duration.zero
      : DateTime.now().difference(analysisStartedAt!);

  Future<Directory> _dataDirectory() async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory('${root.path}/BHE Mobile');
    await directory.create(recursive: true);
    return directory;
  }

  Future<String> _projectPath(
    String id, {
    String area = '',
    String suffix = '',
  }) async => projectStoragePath(
    await _dataDirectory(),
    id,
    area: area,
    suffix: suffix,
  );

  Future<VideoInfo> _inspectVideo(File file, {VideoInfo? expected}) async {
    if (!await file.exists()) {
      throw FileSystemException('Missing source video', file.path);
    }
    final VideoInfo actual;
    final probe = videoProbe;
    if (probe != null) {
      actual = await probe(file);
    } else {
      final controller = VideoPlayerController.file(file);
      try {
        await controller.initialize();
        final value = controller.value;
        actual = VideoInfo(
          path: file.path,
          name: file.uri.pathSegments.last,
          sizeBytes: await file.length(),
          durationMs: value.duration.inMilliseconds,
          width: value.size.width.round(),
          height: value.size.height.round(),
          sha256: await _sha256(file),
        );
      } finally {
        await controller.dispose();
      }
    }
    if (expected != null &&
        (expected.width != actual.width ||
            expected.height != actual.height ||
            (expected.durationMs - actual.durationMs).abs() > 1500 ||
            (expected.sha256 != null && expected.sha256 != actual.sha256))) {
      throw const VideoSourceMismatch();
    }
    return actual;
  }

  Future<VideoInfo> _storeVideo(
    String path,
    ProjectSnapshot snapshot,
    int generation, {
    bool fromPicker = false,
    bool replace = false,
    String? name,
  }) async {
    bool current() => _isCurrentVideoPreparation(generation, snapshot.id);
    return _videoStore.save(
      sourcePath: path,
      projectId: snapshot.id,
      previousPath: snapshot.video?.path,
      fromPicker: fromPicker,
      isCurrent: current,
      validate: (file) =>
          _inspectVideo(file, expected: replace ? null : snapshot.video),
      persist: (localPath, info) async {
        final video = VideoInfo(
          path: localPath,
          name: name ?? snapshot.video?.name ?? info.name,
          sizeBytes: info.sizeBytes,
          durationMs: info.durationMs,
          width: info.width,
          height: info.height,
          sha256: info.sha256,
        );
        final next = snapshot.copyWith(
          video: video,
          name: replace
              ? video.name.replaceFirst(RegExp(r'\.[^.]+$'), '')
              : snapshot.name,
          clearHoopRoi: replace,
          clearRimRoi: replace,
          clearNetRoi: replace,
          candidates: replace ? const [] : snapshot.candidates,
          clearLastAnalysis: replace,
        );
        final task = _saveChain.then((_) async {
          if (!current()) throw const VideoSourceCancelled();
          await _writeProject(next);
          if (!current()) {
            await _writeProject(snapshot);
            throw const VideoSourceCancelled();
          }
          project = next;
          videoSourceRevision++;
        });
        _saveChain = task.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        );
        await task;
      },
    );
  }

  Future<File> _projectFile(String id) async {
    final file = File(
      await _projectPath(id, area: 'projects', suffix: '.json'),
    );
    await file.parent.create(recursive: true);
    return file;
  }

  Future<File> _coverFile(String id) async {
    final file = File(
      await _projectPath(id, area: 'projects', suffix: '_cover.jpg'),
    );
    await file.parent.create(recursive: true);
    return file;
  }

  Future<void> _loadCovers() async {
    final covers = <String, String>{};
    for (final item in recentProjects) {
      final file = await _coverFile(item.id);
      if (await file.exists()) covers[item.id] = file.path;
    }
    coverPaths = covers;
    notifyListeners();
    for (final item in recentProjects) {
      if (!covers.containsKey(item.id)) await _updateCover(item);
    }
  }

  /// Uses the first kept shot that passed the rim check, else the first kept
  /// shot, else the first candidate.
  Future<void> _updateCover(ProjectSnapshot snapshot) async {
    final video = snapshot.video;
    if (video == null || snapshot.candidates.isEmpty) return;
    final candidates = [...snapshot.candidates]
      ..sort((a, b) => a.eventMs.compareTo(b.eventMs));
    final kept = candidates
        .where((item) => item.selection == CandidateSelection.included)
        .toList();
    final cover = kept.firstWhere(
      (item) => item.rimCheckStatus == 'made',
      orElse: () => kept.isEmpty ? candidates.first : kept.first,
    );
    final file = await _coverFile(snapshot.id);
    final saved = await analysisEngine.extractCover(
      videoPath: video.path,
      timeMs: cover.eventMs,
      outputPath: file.path,
    );
    if (!saved) return;
    await FileImage(file).evict();
    coverPaths = {...coverPaths, snapshot.id: file.path};
    notifyListeners();
  }

  Future<String> _sha256(File file) async {
    const sampleSize = 1024 * 1024;
    final handle = await file.open();
    try {
      final length = await handle.length();
      final first = await handle.read(
        length < sampleSize ? length : sampleSize,
      );
      if (length > sampleSize) await handle.setPosition(length - sampleSize);
      final last = length > sampleSize
          ? await handle.read(sampleSize)
          : const <int>[];
      return sha256.convert([
        ...first,
        ...last,
        ...utf8.encode('$length'),
      ]).toString();
    } finally {
      await handle.close();
    }
  }

  Future<bool> _matchesProjectVideo({bool Function()? applyResult}) async {
    final expected = project.video;
    if (expected == null) return false;
    try {
      await _inspectVideo(File(expected.path), expected: expected);
      if (project.video == expected && (applyResult?.call() ?? true)) {
        videoSourceFailure = null;
        errorMessage = null;
      }
      return true;
    } on Object catch (error) {
      if (project.video == expected && (applyResult?.call() ?? true)) {
        _recordVideoFailure(error, expected.path);
      }
      return false;
    }
  }

  Future<void> _validateImportedVideoIfPresent() async {
    final snapshot = project;
    final video = snapshot.video;
    if (video == null) {
      errorMessage = '项目已打开，请重新选择原视频后继续。';
      return;
    }
    final generation = _videoPreparationGeneration;
    try {
      final source = await File(video.path).exists()
          ? video.path
          : await _videoStore.existingVideo(snapshot.id);
      if (source == null) {
        throw FileSystemException('Missing source video', video.path);
      }
      // Existing records may share a legacy cache path. Migration is a copy;
      // only a fresh picker selection grants permission to move its cache.
      await _storeVideo(source, snapshot, generation);
      if (_isCurrentVideoPreparation(generation, snapshot.id)) {
        videoSourceFailure = null;
        errorMessage = null;
      }
    } on VideoSourceCancelled {
      return;
    } on Object catch (error) {
      if (_isCurrentVideoPreparation(generation, snapshot.id)) {
        _recordVideoFailure(error, video.path);
      }
    }
  }

  Future<void> loadSavedProject() async {
    try {
      final directory = await _dataDirectory();
      final indexFile = File('${directory.path}/project_index.json');
      final legacyFile = File('${directory.path}/project.bhe.json');
      if (await indexFile.exists()) {
        final ids =
            (jsonDecode(await indexFile.readAsString()) as List?)
                ?.whereType<String>()
                .where(isSafeProjectId)
                .toSet()
                .toList() ??
            const <String>[];
        final loadedProjects = <ProjectSnapshot>[];
        for (final id in ids) {
          final file = await _projectFile(id);
          if (!await file.exists()) continue;
          try {
            loadedProjects.add(
              const ProjectPackageCodec().decode(await file.readAsString()),
            );
          } on Object catch (error, stack) {
            developer.log(
              'skipping invalid project $id: $error',
              name: 'BHE-Project',
              error: error,
              stackTrace: stack,
            );
          }
        }
        recentProjects = loadedProjects;
        if (recentProjects.isNotEmpty) project = recentProjects.first;
        await _persistProjects();
        unawaited(_loadCovers());
      } else if (await legacyFile.exists()) {
        project = const ProjectPackageCodec().decode(
          await legacyFile.readAsString(),
        );
        recentProjects = [project];
        await _persistProjects();
      }
      if (project.video != null) await _validateImportedVideoIfPresent();
      if (project.lastAnalysisStatus == 'running') {
        unawaited(_recoverRunningAnalysis());
      }
    } on Object catch (error) {
      errorMessage = '读取本地项目失败：$error';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _recoverRunningAnalysis() async {
    var receivedState = false;
    try {
      await for (final update in analysisEngine.recoverAnalysis()) {
        receivedState = true;
        stage = update.stage;
        progress = update.progress.clamp(0, 1);
        progressMessage = update.message;
        processedFrames = update.processedFrames;
        totalFrames = update.totalFrames;
        analysing =
            update.stage != AnalysisStage.completed &&
            update.stage != AnalysisStage.cancelled &&
            update.stage != AnalysisStage.failed;
        analysisStartedAt ??= DateTime.now();
        if (update.stage == AnalysisStage.completed) {
          project = project.copyWith(
            candidates: update.candidates,
            lastAnalysisStatus: 'completed',
            lastAnalysisProgressPercent: 100,
            lastAnalysisMessage: '分析完成',
            lastAnalysisAt: DateTime.now(),
          );
          analysing = false;
          analysisStartedAt = null;
          await _queueSave();
          unawaited(_updateCover(project));
        } else if (update.stage == AnalysisStage.cancelled ||
            update.stage == AnalysisStage.failed) {
          project = project.copyWith(
            lastAnalysisStatus: update.stage == AnalysisStage.cancelled
                ? 'cancelled'
                : 'failed',
            lastAnalysisMessage: update.message,
          );
          analysing = false;
          analysisStartedAt = null;
          await _queueSave();
        } else {
          project = project.copyWith(
            lastAnalysisStatus: 'running',
            lastAnalysisProgressPercent: (progress * 100).round(),
            lastAnalysisMessage: update.message,
          );
          unawaited(_queueSave());
        }
        notifyListeners();
      }
      if (!receivedState && project.lastAnalysisStatus == 'running') {
        project = project.copyWith(
          lastAnalysisStatus: 'interrupted',
          lastAnalysisMessage: '未找到仍在运行的原生分析任务，可重新分析。',
        );
        await _queueSave();
        notifyListeners();
      }
    } on Object catch (error) {
      project = project.copyWith(
        lastAnalysisStatus: 'interrupted',
        lastAnalysisMessage: '无法恢复原生分析任务：$error',
      );
      analysing = false;
      analysisStartedAt = null;
      unawaited(_queueSave());
      notifyListeners();
    }
  }

  Future<void> _writeProject(ProjectSnapshot snapshot) async {
    final file = await _projectFile(snapshot.id);
    final next = [
      snapshot,
      ...recentProjects.where((item) => item.id != snapshot.id),
    ].take(12).toList();
    final index = File('${(await _dataDirectory()).path}/project_index.json');
    await commitProjectFiles({
      file: const ProjectPackageCodec().encode(snapshot),
      index: jsonEncode(next.map((item) => item.id).toList()),
    });
    recentProjects = next;
  }

  Future<void> _persistProjects() async {
    final directory = await _dataDirectory();
    final indexFile = File('${directory.path}/project_index.json');
    await indexFile.writeAsString(
      jsonEncode(recentProjects.map((item) => item.id).toList()),
    );
  }

  Future<void> openProject(String id) async {
    if (analysing) await cancelAnalysis();
    _invalidateVideoPreparation();
    await _saveChain;
    final file = await _projectFile(id);
    if (!await file.exists()) return;
    project = const ProjectPackageCodec().decode(await file.readAsString());
    _resetTransientState();
    errorMessage = null;
    exportedPaths = const [];
    exportAudioSkipped = false;
    await _validateImportedVideoIfPresent();
    recentProjects = [
      project,
      ...recentProjects.where((item) => item.id != project.id),
    ];
    await _persistProjects();
    notifyListeners();
  }

  Future<void> createNewProject() async {
    if (analysing) await cancelAnalysis();
    _invalidateVideoPreparation();
    if (project.video != null) await _queueSave();
    project = _newProject();
    _resetTransientState();
    notifyListeners();
  }

  ProjectSnapshot _newProject() =>
      ProjectSnapshot(id: _newProjectId(), name: '新项目', video: null);

  String _newProjectId() {
    var id = DateTime.now().microsecondsSinceEpoch.toString();
    final usedIds = {project.id, ...recentProjects.map((item) => item.id)};
    var suffix = 0;
    while (usedIds.contains(id)) {
      id = '${DateTime.now().microsecondsSinceEpoch}_${suffix++}';
    }
    return id;
  }

  Future<void> createNewProjectAndPickVideo() async {
    if (analysing) await cancelAnalysis();
    _invalidateVideoPreparation();
    final picked = await _pickVideo();
    if (picked == null) return;
    await createNewProject();
    await _prepareVideo(picked.path, name: picked.name);
  }

  Future<void> _queueSave() {
    final snapshot = project;
    _saveChain = _saveChain.then<void>(
      (_) => _writeProject(snapshot),
      onError: (Object error, StackTrace stack) => _writeProject(snapshot),
    );
    return _saveChain;
  }

  Future<void> pickVideo() async {
    if (analysing) await cancelAnalysis();
    _invalidateVideoPreparation();
    final picked = await _pickVideo();
    if (picked == null) return;
    await _prepareVideo(picked.path, name: picked.name);
  }

  Future<({String path, String name})?> _pickVideo() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.video);
    final file = result?.files.single;
    final path = file?.path;
    if (path == null) return null;
    final pathName = path.split(Platform.pathSeparator).last;
    return (
      path: path,
      name: file?.name.trim().isNotEmpty == true ? file!.name : pathName,
    );
  }

  Future<void> _prepareVideo(String path, {String? name}) async {
    final projectId = project.id;
    final preparationGeneration = ++_videoPreparationGeneration;
    videoSourceFailure = null;
    preparingVideo = true;
    preparingVideoMessage = '正在读取视频信息';
    errorMessage = null;
    notifyListeners();
    try {
      preparingVideoMessage = '正在保存视频到本机';
      notifyListeners();
      await _storeVideo(
        path,
        project,
        preparationGeneration,
        fromPicker: true,
        replace: true,
        name: name,
      );
      if (!_isCurrentVideoPreparation(preparationGeneration, projectId)) return;
      errorMessage = null;
      preparingVideoMessage = '正在识别篮筐区域';
      notifyListeners();
      try {
        final suggestion = await analysisEngine.suggestRoi(
          video: project.video!,
          startMs: project.settings.startMs,
          modelSize: project.settings.modelInputSize,
        );
        if (!_isCurrentVideoPreparation(preparationGeneration, projectId)) {
          return;
        }
        final rawRoi = suggestion?['roi'];
        if (rawRoi is Map) {
          final analysisRoi = Roi.fromJson(
            rawRoi.map((key, value) => MapEntry(key.toString(), value)),
          );
          final rawNet = suggestion?['net_roi'];
          final rawRim = suggestion?['rim_roi'];
          final rimRoi = rawRim is Map
              ? Roi.fromJson(
                  rawRim.map((key, value) => MapEntry(key.toString(), value)),
                )
              : null;
          final netRoi = rawNet is Map
              ? Roi.fromJson(
                  rawNet.map((key, value) => MapEntry(key.toString(), value)),
                )
              : rimRoi != null
              ? netRoiFromRim(analysisRoi, rimRoi)
              : Roi(
                  left: analysisRoi.left,
                  top: (analysisRoi.top + .06).clamp(0, 1),
                  right: analysisRoi.right,
                  bottom: (analysisRoi.bottom + .18).clamp(0, 1),
                );
          project = project.copyWith(
            hoopRoi: analysisRoi,
            rimRoi: rimRoi,
            netRoi: netRoi,
          );
          await _queueSave();
        }
      } on Object catch (error, stack) {
        developer.log(
          'automatic ROI suggestion failed: $error',
          name: 'BHE-Project',
          error: error,
          stackTrace: stack,
        );
      }
    } on VideoSourceCancelled {
      return;
    } on Object catch (error, stack) {
      developer.log(
        'video preparation failed: $error',
        name: 'BHE-Project',
        error: error,
        stackTrace: stack,
      );
      if (_isCurrentVideoPreparation(preparationGeneration, projectId)) {
        _recordVideoFailure(error, path);
      }
    } finally {
      if (preparationGeneration == _videoPreparationGeneration) {
        preparingVideo = false;
        preparingVideoMessage = '';
        notifyListeners();
      }
    }
  }

  bool _isCurrentVideoPreparation(int generation, String projectId) =>
      !_disposed &&
      generation == _videoPreparationGeneration &&
      project.id == projectId;

  void _invalidateVideoPreparation() {
    _videoPreparationGeneration++;
    preparingVideo = false;
    preparingVideoMessage = '';
    _relinkSerial++;
    relinkingVideo = false;
    relinkCancelling = false;
  }

  void _resetTransientState() {
    videoSourceFailure = null;
    errorMessage = null;
    stage = AnalysisStage.idle;
    progress = 0;
    progressMessage = '';
    processedFrames = null;
    totalFrames = null;
    eta = null;
    analysing = false;
    exporting = false;
    exportedPaths = const [];
    exportAudioSkipped = false;
    analysisStartedAt = null;
  }

  Future<void> importProject() async {
    if (analysing) await cancelAnalysis();
    _invalidateVideoPreparation();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['bhe', 'json'],
    );
    final file = result?.files.single;
    final path = file?.path;
    if (path == null) return;
    try {
      if (project.video != null) await _queueSave();
      final file = File(path);
      final content = path.toLowerCase().endsWith('.bhe')
          ? _readProjectFromArchive(await file.readAsBytes())
          : await file.readAsString();
      final imported = const ProjectPackageCodec().decode(
        content,
        existingIds: [
          project.id,
          ...recentProjects.map((item) => item.id),
          ...await existingProjectStorageIds(await _dataDirectory()),
        ],
      );
      project = imported;
      _resetTransientState();
      errorMessage = null;
      await _validateImportedVideoIfPresent();
      await _queueSave();
      notifyListeners();
    } on Object catch (error) {
      errorMessage = '项目包无法打开：$error';
      notifyListeners();
    }
  }

  Future<void> relinkVideo() async {
    if (relinkingVideo || preparingVideo || exporting) return;
    var snapshot = project;
    final generation = ++_videoPreparationGeneration;
    final operation = ++_relinkSerial;
    relinkingVideo = true;
    relinkCancelling = false;
    notifyListeners();
    String? path;
    bool current() => _isCurrentVideoPreparation(generation, snapshot.id);
    try {
      if (analysing) {
        await cancelAnalysis();
        if (!current()) return;
        snapshot = snapshot.copyWith(
          lastAnalysisStatus: project.lastAnalysisStatus,
          lastAnalysisMessage: project.lastAnalysisMessage,
        );
      }
      if (!current()) return;
      final picked = await _pickVideo();
      if (picked == null || !current()) return;
      path = picked.path;
      await _storeVideo(
        path,
        snapshot,
        generation,
        fromPicker: true,
        name: picked.name,
      );
      if (!current()) return;
      videoSourceFailure = null;
      errorMessage = null;
    } on VideoSourceCancelled {
      // Switching project, cancelling, or closing never changes the new page.
    } on Object catch (error) {
      if (current()) _recordVideoFailure(error, path);
    } finally {
      if (!_disposed && operation == _relinkSerial) {
        relinkingVideo = false;
        relinkCancelling = false;
        notifyListeners();
      }
    }
  }

  void updateSettings(AnalysisSettings settings) {
    project = project.copyWith(settings: settings);
    unawaited(_queueSave());
    notifyListeners();
  }

  void updateRoi(Roi roi) {
    updateRois(
      hoop: roi,
      net: Roi(
        left: roi.left,
        top: (roi.top + .06).clamp(0, 1),
        right: roi.right,
        bottom: (roi.bottom + .18).clamp(0, 1),
      ),
    );
  }

  void updateRois({required Roi hoop, required Roi net}) {
    project = project.copyWith(
      hoopRoi: hoop,
      // `hoopRoi` is the large ball-search/analysis area. Keep the separately
      // calibrated physical rim when that broad area is adjusted.
      netRoi: net,
    );
    unawaited(_queueSave());
    notifyListeners();
  }

  Future<void> clearProject() async {
    if (analysing) await cancelAnalysis();
    _invalidateVideoPreparation();
    await _saveChain;
    final deletedId = project.id;
    stage = AnalysisStage.idle;
    errorMessage = null;
    _resetTransientState();
    final file = await _projectFile(deletedId);
    if (await file.exists()) await file.delete();
    final cover = await _coverFile(deletedId);
    if (await cover.exists()) await cover.delete();
    coverPaths = {...coverPaths}..remove(deletedId);
    recentProjects = recentProjects
        .where((item) => item.id != deletedId)
        .toList();
    await _persistProjects();
    if (recentProjects.isEmpty) {
      project = _newProject();
    } else {
      project = recentProjects.first;
      exportedPaths = const [];
      exportAudioSkipped = false;
      await _validateImportedVideoIfPresent();
    }
    final directory = await _dataDirectory();
    for (final name in ['project.bhe.json', 'project.bhe']) {
      final legacy = File('${directory.path}/$name');
      if (await legacy.exists()) await legacy.delete();
    }
    for (final name in ['exports', 'package_staging']) {
      final artifactDirectory = Directory(
        await _projectPath(deletedId, area: name),
      );
      if (await artifactDirectory.exists()) {
        await artifactDirectory.delete(recursive: true);
      }
    }
    final videoDirectory = Directory(
      await _projectPath(deletedId, area: 'videos'),
    );
    if (await videoDirectory.exists()) {
      await videoDirectory.delete(recursive: true);
    }
    notifyListeners();
  }

  void toggleCandidate(String id, CandidateSelection selection) {
    project = project.copyWith(
      candidates: project.candidates
          .map(
            (candidate) => candidate.id == id
                ? candidate.copyWith(selection: selection, reviewed: true)
                : candidate,
          )
          .toList(),
    );
    unawaited(_queueSave());
    notifyListeners();
  }

  void addCandidate(Candidate candidate) {
    final candidates = [...project.candidates, candidate]
      ..sort((a, b) => a.eventMs.compareTo(b.eventMs));
    project = project.copyWith(candidates: candidates);
    unawaited(_queueSave());
    notifyListeners();
  }

  void setAllCandidates(CandidateSelection selection) {
    project = project.copyWith(
      candidates: project.candidates
          .map((candidate) => candidate.copyWith(selection: selection))
          .toList(),
    );
    unawaited(_queueSave());
    notifyListeners();
  }

  void setCandidatePlayer(String id, String? player) {
    project = project.copyWith(
      candidates: project.candidates
          .map(
            (candidate) => candidate.id == id
                ? candidate.copyWith(
                    player: player,
                    clearPlayer: player == null,
                  )
                : candidate,
          )
          .toList(),
    );
    unawaited(_queueSave());
    notifyListeners();
  }

  void addPlayer(String player) {
    final normalized = player.trim();
    if (normalized.isEmpty || project.players.contains(normalized)) return;
    project = project.copyWith(players: [...project.players, normalized]);
    unawaited(_queueSave());
    notifyListeners();
  }

  void removePlayer(String player) {
    project = project.copyWith(
      players: project.players.where((item) => item != player).toList(),
      candidates: project.candidates
          .map(
            (candidate) => candidate.player == player
                ? candidate.copyWith(clearPlayer: true)
                : candidate,
          )
          .toList(),
    );
    unawaited(_queueSave());
    notifyListeners();
  }

  Future<void> _loadPlayerGroups() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(playerGroupsPrefsKey);
      if (raw == null) return;
      playerGroups = [
        for (final item in jsonDecode(raw) as List)
          (
            name: (item as Map)['name'].toString(),
            players: [for (final name in item['players'] as List) '$name'],
          ),
      ];
      notifyListeners();
    } on Object catch (error) {
      developer.log('player groups unreadable: $error', name: 'BHE-Project');
    }
  }

  Future<void> _persistPlayerGroups() async {
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      playerGroupsPrefsKey,
      jsonEncode([
        for (final group in playerGroups)
          {'name': group.name, 'players': group.players},
      ]),
    );
  }

  Future<void> savePlayerGroup(String name) async {
    playerGroups = [
      for (final group in playerGroups)
        if (group.name != name) group,
      (name: name, players: [...project.players]),
    ];
    await _persistPlayerGroups();
  }

  Future<void> deletePlayerGroup(String name) async {
    playerGroups = [
      for (final group in playerGroups)
        if (group.name != name) group,
    ];
    await _persistPlayerGroups();
  }

  void importPlayers(List<String> players) {
    final missing = players.where((item) => !project.players.contains(item));
    if (missing.isEmpty) return;
    project = project.copyWith(players: [...project.players, ...missing]);
    unawaited(_queueSave());
    notifyListeners();
  }

  Future<void> exportProjectPackage() async {
    final staging = Directory(
      await _projectPath(project.id, area: 'package_staging'),
    );
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    final projectJson = File('${staging.path}/project.json');
    await projectJson.writeAsString(
      const ProjectPackageCodec().encode(project),
    );
    final file = File(await _projectPath(project.id, suffix: '.bhe'));
    final encoder = ZipFileEncoder()
      ..create(file.path, level: ZipFileEncoder.store);
    encoder.addFileSync(projectJson, 'project.json');
    encoder.closeSync();
    await staging.delete(recursive: true);
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  }

  Future<void> exportClips() async {
    await exportClipsForPlayer(null);
  }

  Future<void> mergeClips() async {
    await mergeClipsForPlayer(null);
  }

  Future<void> exportClipsForPlayer(String? player) async {
    if (exporting) return;
    if (!await _matchesProjectVideo()) {
      errorMessage ??= '请先重新选择原视频。';
      notifyListeners();
      return;
    }
    final candidates = project.candidates
        .where(
          (candidate) => candidate.selection == CandidateSelection.included,
        )
        .where((candidate) => player == null || candidate.player == player)
        .toList();
    if (candidates.isEmpty) {
      errorMessage = '没有符合条件的保留片段。';
      notifyListeners();
      return;
    }
    exporting = true;
    exportCancelled = false;
    exportedPaths = const [];
    exportAudioSkipped = false;
    final stopwatch = Stopwatch()..start();
    errorMessage = null;
    try {
      await for (final update in exportEngine.exportClips(
        video: project.video!,
        candidates: candidates,
        outputDirectory: await _projectPath(project.id, area: 'exports'),
      )) {
        exportAudioSkipped |= update.skippedAudioTracks.isNotEmpty;
        progress = update.progress;
        progressMessage = update.message;
        if (update.outputPath != null) {
          exportedPaths = [...exportedPaths, update.outputPath!];
        }
        notifyListeners();
      }
      project = project.copyWith(
        lastExportDurationMs: stopwatch.elapsedMilliseconds,
      );
      await _queueSave();
    } on Object catch (error) {
      errorMessage = error.toString();
      notifyListeners();
    } finally {
      stopwatch.stop();
      exporting = false;
      notifyListeners();
    }
  }

  Future<void> mergeClipsForPlayer(String? player) async {
    if (exporting) return;
    if (!await _matchesProjectVideo()) {
      errorMessage ??= '请先重新选择原视频。';
      notifyListeners();
      return;
    }
    final candidates =
        project.candidates
            .where(
              (candidate) => candidate.selection == CandidateSelection.included,
            )
            .where((candidate) => player == null || candidate.player == player)
            .toList()
          ..sort((a, b) => a.startMs.compareTo(b.startMs));
    if (candidates.isEmpty) {
      errorMessage = '没有符合条件的保留片段。';
      notifyListeners();
      return;
    }
    exporting = true;
    exportCancelled = false;
    exportedPaths = const [];
    exportAudioSkipped = false;
    final stopwatch = Stopwatch()..start();
    errorMessage = null;
    try {
      final outputPath =
          '${await _projectPath(project.id, area: 'exports')}/${project.id}_merged.mp4';
      await for (final update in exportEngine.mergeClips(
        video: project.video!,
        candidates: candidates,
        outputPath: outputPath,
      )) {
        exportAudioSkipped |= update.skippedAudioTracks.isNotEmpty;
        progress = update.progress;
        progressMessage = update.message;
        if (update.outputPath != null) {
          exportedPaths = [update.outputPath!];
        }
        notifyListeners();
      }
      project = project.copyWith(
        lastExportDurationMs: stopwatch.elapsedMilliseconds,
      );
      await _queueSave();
    } on Object catch (error) {
      errorMessage = error.toString();
      notifyListeners();
    } finally {
      stopwatch.stop();
      exporting = false;
      notifyListeners();
    }
  }

  Future<void> cancelExport() async {
    if (!exporting) return;
    exportCancelled = true;
    try {
      await exportEngine.cancel();
      progressMessage = '导出已取消';
    } on Object catch (error) {
      errorMessage = error.toString();
    }
    notifyListeners();
  }

  Future<void> shareExportedFiles() async {
    if (exportedPaths.isEmpty) return;
    await SharePlus.instance.share(
      ShareParams(files: exportedPaths.map(XFile.new).toList()),
    );
  }

  Future<void> saveExportedFiles() async {
    if (exportedPaths.isEmpty) return;
    exporting = true;
    errorMessage = null;
    try {
      for (var index = 0; index < exportedPaths.length; index++) {
        progress = index / exportedPaths.length;
        progressMessage = '正在保存到相册 ${index + 1}/${exportedPaths.length}';
        notifyListeners();
        await exportEngine.saveToLibrary(exportedPaths[index]);
      }
      progress = 1;
      progressMessage = '已保存 ${exportedPaths.length} 个片段到相册';
    } on Object catch (error) {
      errorMessage = error.toString();
    } finally {
      exporting = false;
      notifyListeners();
    }
  }

  Future<void> startAnalysis() async {
    if (analysing) return;
    if (!hasVideo || project.hoopRoi == null || project.netRoi == null) {
      errorMessage = '请先选择视频并设置投篮分析区、篮网检测区。';
      notifyListeners();
      return;
    }
    stage = AnalysisStage.validateInput;
    progress = 0.01;
    progressMessage = '正在检查视频';
    analysing = true;
    errorMessage = null;
    final stopwatch = Stopwatch()..start();
    final generation = ++_analysisGeneration;
    analysisStartedAt = DateTime.now();
    notifyListeners();
    try {
      var checkingInput = true;
      final videoMatches =
          await _matchesProjectVideo(
            applyResult: () =>
                checkingInput && generation == _analysisGeneration,
          ).timeout(
            const Duration(seconds: 45),
            onTimeout: () {
              checkingInput = false;
              return false;
            },
          );
      checkingInput = false;
      if (generation != _analysisGeneration) return;
      if (!videoMatches) {
        throw const MobileAnalysisException('视频检查未通过或耗时过长，请重新选择可正常播放的原视频。');
      }
      project = project.copyWith(
        candidates: const [],
        lastAnalysisStatus: 'running',
        lastAnalysisProgressPercent: 0,
        lastAnalysisMessage: progressMessage,
      );
      await _queueSave();
      if (generation != _analysisGeneration) return;
      progress = 0.02;
      progressMessage = '正在准备本地分析';
      notifyListeners();
      await for (final update in analysisEngine.analyze(
        video: project.video!,
        hoopRoi: project.hoopRoi!,
        rimRoi: project.rimRoi,
        netRoi: project.netRoi!,
        settings: project.settings,
      )) {
        if (generation != _analysisGeneration) break;
        stage = update.stage;
        progress = update.progress.clamp(0, 1);
        progressMessage = update.message;
        processedFrames = update.processedFrames;
        totalFrames = update.totalFrames;
        eta = update.eta;
        project = project.copyWith(candidates: update.candidates);
        final percent = (progress * 100).round();
        project = project.copyWith(
          lastAnalysisStatus: 'running',
          lastAnalysisProgressPercent: percent,
          lastAnalysisMessage: update.message,
        );
        if (percent == 100 || percent % 5 == 0) unawaited(_queueSave());
        notifyListeners();
      }
      if (generation != _analysisGeneration) return;
      stopwatch.stop();
      project = project.copyWith(
        lastAnalysisDurationMs: stopwatch.elapsedMilliseconds,
        lastAnalysisAt: DateTime.now(),
        lastAnalysisStatus: 'completed',
        lastAnalysisProgressPercent: 100,
        lastAnalysisMessage: '分析完成',
      );
      await _queueSave();
      unawaited(_updateCover(project));
    } on Object catch (error) {
      if (generation != _analysisGeneration) return;
      stage = AnalysisStage.failed;
      errorMessage = videoSourceFailure?.message ?? error.toString();
      project = project.copyWith(
        lastAnalysisStatus: 'failed',
        lastAnalysisMessage: errorMessage,
      );
      unawaited(_queueSave());
      notifyListeners();
    } finally {
      stopwatch.stop();
      if (generation == _analysisGeneration) {
        analysing = false;
        analysisStartedAt = null;
        notifyListeners();
      }
    }
  }

  Future<void> cancelAnalysis() async {
    if (!analysing) return;
    final generation = ++_analysisGeneration;
    final projectId = project.id;
    await analysisEngine.cancel();
    if (generation != _analysisGeneration ||
        project.id != projectId ||
        _disposed) {
      return;
    }
    analysing = false;
    analysisStartedAt = null;
    stage = AnalysisStage.cancelled;
    progressMessage = '分析已取消';
    project = project.copyWith(
      lastAnalysisStatus: 'cancelled',
      lastAnalysisMessage: progressMessage,
    );
    unawaited(_queueSave());
    notifyListeners();
  }

  void updateCandidate(Candidate candidate) {
    project = project.copyWith(
      candidates: project.candidates
          .map((item) => item.id == candidate.id ? candidate : item)
          .toList(),
    );
    unawaited(_queueSave());
    notifyListeners();
  }

  /// Applies an event-centered clip range to all or selected candidates.
  /// Manually edited ranges are preserved unless explicitly overwritten.
  int applyBatchClipRange({
    required int beforeSeconds,
    required int afterSeconds,
    Iterable<String>? candidateIds,
    bool overwriteManual = false,
  }) {
    final video = project.video;
    if (video == null) return 0;
    final ids = candidateIds?.toSet();
    var updated = 0;
    final beforeMs = beforeSeconds.clamp(0, 3600) * 1000;
    final afterMs = afterSeconds.clamp(0, 3600) * 1000;
    final candidates = project.candidates.map((candidate) {
      if (ids != null && !ids.contains(candidate.id)) return candidate;
      if (candidate.rangeEdited && !overwriteManual) return candidate;
      final start = (candidate.eventMs - beforeMs)
          .clamp(0, video.durationMs)
          .toInt();
      final end = (candidate.eventMs + afterMs)
          .clamp(0, video.durationMs)
          .toInt();
      if (end <= start) return candidate;
      updated++;
      return candidate.copyWith(startMs: start, endMs: end, rangeEdited: false);
    }).toList();
    if (updated == 0) return 0;
    project = project.copyWith(candidates: candidates);
    unawaited(_queueSave());
    notifyListeners();
    return updated;
  }

  void updateCandidateNote(String id, String? note) {
    project = project.copyWith(
      candidates: project.candidates
          .map(
            (item) => item.id == id
                ? item.copyWith(
                    note: note,
                    clearNote: note == null || note.trim().isEmpty,
                  )
                : item,
          )
          .toList(),
    );
    unawaited(_queueSave());
    notifyListeners();
  }
}

Roi netRoiFromRim(Roi analysisRoi, Roi rimRoi) {
  final centerX = (rimRoi.left + rimRoi.right) / 2;
  final rimWidth = (rimRoi.right - rimRoi.left).clamp(0.004, 1.0).toDouble();
  final rimHeight = (rimRoi.bottom - rimRoi.top).clamp(0.008, 1.0).toDouble();
  final analysisWidth = analysisRoi.right - analysisRoi.left;
  final width = (rimWidth * 1.5)
      .clamp(analysisWidth * 0.08, analysisWidth * 0.34)
      .toDouble();
  final left = (centerX - width / 2).clamp(
    analysisRoi.left,
    analysisRoi.right - width,
  );
  final right = left + width;
  // The net starts below the physical rim, not at the top edge of the rim
  // detection box. Using rimRoi.top makes the net overlay appear vertically
  // flipped and includes the backboard/upper hoop area.
  final top = rimRoi.bottom
      .clamp(analysisRoi.top, analysisRoi.bottom)
      .toDouble();
  final bottom = analysisRoi.bottom < top + 4.5 * rimHeight
      ? analysisRoi.bottom
      : top + 4.5 * rimHeight;
  return Roi(
    left: left.clamp(0.0, 1.0).toDouble(),
    top: top.clamp(0.0, 1.0).toDouble(),
    right: right.clamp(0.0, 1.0).toDouble(),
    bottom: bottom.clamp(0.0, 1.0).toDouble(),
  );
}

String _readProjectFromArchive(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final project = archive.files.cast<ArchiveFile?>().firstWhere(
    (file) => file?.name == 'project.json',
    orElse: () => null,
  );
  if (project == null) throw const FormatException('项目包缺少 project.json');
  return utf8.decode(project.readBytes() ?? const <int>[]);
}
