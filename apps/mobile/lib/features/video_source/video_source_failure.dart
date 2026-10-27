enum VideoSourceFailure {
  missing('视频文件找不到了，请重新选择原视频。', true),
  unplayable('这个视频无法播放，请重新选择原视频。', false),
  mismatch('所选视频与项目记录不一致，请选择原始视频。', true);

  const VideoSourceFailure(this.message, this.canRelink);
  final String message;
  final bool canRelink;
}
