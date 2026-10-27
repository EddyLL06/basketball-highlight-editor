from pathlib import Path
import os
import subprocess

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_production_writers_share_one_lock_and_one_publishing_script():
    primary = yaml.safe_load((ROOT / '.github/workflows/release-packages.yml').read_text())
    manual = yaml.safe_load((ROOT / '.github/workflows/upload-release-assets-oss.yml').read_text())
    jobs = [primary['jobs']['oss-upload'], manual['jobs']['upload']]
    for job in jobs:
        assert job['concurrency']['cancel-in-progress'] is False
        assert "'bhe-production-update-channel-v1'" in job['concurrency']['group']
        assert "'bhe-dryrun-update-channel-v1'" in job['concurrency']['group']
        scripts = '\n'.join(s.get('run', '') for s in job['steps'])
        assert 'publish_release_update.py' in scripts
        assert 'cp -f' not in scripts and 'cp -r' not in scripts
        assert 'Publish signed update manifest' not in scripts
    for workflow in [primary, manual]:
        assert workflow['jobs']['publication-status']['if'] == 'always()'
    assert "github.event_name == 'workflow_dispatch'" in primary['jobs']['oss-upload']['if']


def test_release_plan_platform_and_oss_controls(tmp_path):
    workflow = yaml.safe_load((ROOT / '.github/workflows/release-packages.yml').read_text())
    script = workflow['jobs']['release-plan']['steps'][0]['run']
    subprocess.run(['bash', '-n'], input=script, text=True, check=True)
    for event, tag, platform, publish, oss, expected in [
        ('push', 'v0.1.13', '', '', '', 'false'),
        ('push', 'v0.1.13-android.1', '', '', '', 'false'),
        ('push', 'v0.1.13-macos.1', '', '', '', 'false'),
        ('push', 'v0.1.13-windows.1', '', '', '', 'false'),
        ('push', 'v0.1.13-dryrun', '', '', '', 'false'),
        ('workflow_dispatch', 'v0.1.13-android.1', 'android', 'true', 'false', 'false'),
        ('workflow_dispatch', 'v0.1.13', 'all', 'false', 'true', 'false'),
    ]:
        output = tmp_path / 'output'
        output.write_text('')
        env = dict({'PATH': os.environ['PATH']}, EVENT_NAME=event, REF_NAME=tag, SHA='test', INPUT_TAG=tag,
                   INPUT_PLATFORM=platform, INPUT_PUBLISH=publish, INPUT_PUBLISH_OSS=oss, INPUT_DRY_RUN='false',
                   GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(tmp_path / 'summary'))
        subprocess.run(['bash', '-euo', 'pipefail', '-c', script], env=env, check=True)
        fields = dict(line.split('=', 1) for line in output.read_text().splitlines())
        assert fields['publish_oss'] == expected
        if event == 'push': assert fields['publish'] == 'true'
        if '-android.' in tag:
            assert fields['build_macos'] == fields['build_windows'] == 'false'
            assert fields['build_android'] == 'true'


def test_all_workflow_yaml_and_bash_scripts_parse():
    for path in (ROOT / '.github/workflows').glob('*.yml'):
        workflow = yaml.safe_load(path.read_text())
        assert isinstance(workflow.get('jobs'), dict)
        for job in workflow['jobs'].values():
            for step in job.get('steps', []):
                if step.get('shell') == 'bash' and 'run' in step:
                    subprocess.run(['bash', '-n'], input=step['run'], text=True, check=True)
    subprocess.run(['bash', '-n', str(ROOT / 'scripts/upload_release_assets_oss.sh')], check=True)


def test_legacy_local_uploader_cannot_bypass_production_lock():
    result = subprocess.run(['bash', str(ROOT / 'scripts/upload_release_assets_oss.sh'), 'v0.1.13-android.1'], capture_output=True, text=True)
    assert result.returncode == 2
    assert 'GitHub Actions' in result.stderr
    assert 'ossutil cp' not in (ROOT / 'scripts/upload_release_assets_oss.sh').read_text()


def test_dry_run_workflow_inputs_and_tag_guards(tmp_path):
    primary = yaml.safe_load((ROOT / '.github/workflows/release-packages.yml').read_text())
    manual = yaml.safe_load((ROOT / '.github/workflows/upload-release-assets-oss.yml').read_text())
    # PyYAML treats the YAML 1.1 key "on" as the boolean True.
    for workflow, job_name in [(primary, 'oss-upload'), (manual, 'upload')]:
        input_def = workflow[True]['workflow_dispatch']['inputs']['dry_run']
        assert input_def['type'] == 'boolean'
        assert input_def['default'] is (job_name == 'upload')
        job = workflow['jobs'][job_name]
        assert job['concurrency']['cancel-in-progress'] is False
        assert "'bhe-production-update-channel-v1'" in job['concurrency']['group']
        assert "'bhe-dryrun-update-channel-v1'" in job['concurrency']['group']
        assert any(s.get('uses', '').startswith('actions/upload-artifact@') and s.get('if') == 'always()'
                   for s in job['steps'])
        assert '未写入 OSS 发布对象；Actions 产物中保存演练文件' in workflow['jobs']['publication-status']['steps'][0]['run']
        script = next(s['run'] for s in job['steps'] if s.get('name') == 'Publish verified update channel')
        # Run the real shell step against fake executables: no credentials or network.
        bindir = tmp_path / job_name
        bindir.mkdir()
        for binary, body in [('ossutil', 'exit 0'), ('python3', 'if [[ "$1" == -c ]]; then echo status=dry-run-ok; else printf "%s\\n" "$@" > "$ARG_LOG"; fi')]:
            path = bindir / binary
            path.write_text('#!/bin/bash\n' + body + '\n')
            path.chmod(0o755)
        for dry in ('true', 'false'):
            arglog = bindir / ('args-' + dry)
            env = dict(os.environ, PATH=str(bindir) + ':' + os.environ['PATH'], RUNNER_TEMP=str(bindir),
                       UPDATE_SIGNING_KEY='fake', ALIBABA_CLOUD_ACCESS_KEY_ID='fake',
                       ALIBABA_CLOUD_ACCESS_KEY_SECRET='fake', ALIBABA_CLOUD_SECURITY_TOKEN='fake',
                       OSS_ENDPOINT='fake', TAG_NAME='v0.1.13', RELEASE_PLATFORM='all', OSS_BUCKET='oss://fake',
                       OSS_PREFIX='releases', OSS_ANDROID_KEY='android/latest.apk', DRY_RUN=dry, ARG_LOG=str(arglog), GITHUB_OUTPUT=str(bindir / 'output'))
            subprocess.run(['bash', '-euo', 'pipefail', '-c', script], env=env, check=True)
            assert ('--dry-run' in arglog.read_text().splitlines()) == (dry == 'true')
    job = primary['jobs']['oss-upload']
    assert job['env']['DRY_RUN'] == "${{ github.event_name == 'workflow_dispatch' && inputs.dry_run }}"
    assert primary[True]['push']['tags'] == ['v*']
    release_step = next(s for s in primary['jobs']['release']['steps'] if s.get('name') == 'Publish GitHub Release')
    assert release_step['if'] == "${{ !(github.event_name == 'workflow_dispatch' && inputs.dry_run) }}"
    assert any(s.get('name') == 'Download built assets for rehearsal' and
               s.get('if') == "${{ github.event_name == 'workflow_dispatch' && inputs.dry_run }}" for s in job['steps'])


def test_release_plan_dry_run_input_matrix(tmp_path):
    workflow = yaml.safe_load((ROOT / '.github/workflows/release-packages.yml').read_text())
    script = workflow['jobs']['release-plan']['steps'][0]['run']
    for event in ('push', 'workflow_dispatch'):
        for publish in ('true', 'false'):
            for oss in ('true', 'false'):
                for dry in ('true', 'false'):
                    output = tmp_path / 'out'
                    output.write_text('')
                    env = dict(os.environ, EVENT_NAME=event, REF_NAME='v0.1.13-android.1', SHA='test',
                               INPUT_TAG='v0.1.13-android.1', INPUT_PLATFORM='android', INPUT_PUBLISH=publish,
                               INPUT_PUBLISH_OSS=oss, INPUT_DRY_RUN=dry, GITHUB_OUTPUT=str(output),
                               GITHUB_STEP_SUMMARY=str(tmp_path / 'summary'))
                    result = subprocess.run(['bash', '-euo', 'pipefail', '-c', script], env=env, capture_output=True, text=True)
                    invalid = event == 'workflow_dispatch' and dry == 'true' and (publish != 'true' or oss != 'true')
                    assert (result.returncode != 0) == invalid
                    if invalid:
                        assert 'publish' in result.stderr and 'publish_oss' in result.stderr
                        continue
                    fields = dict(line.split('=', 1) for line in output.read_text().splitlines())
                    assert fields['build_android'] == 'true' and fields['build_macos'] == fields['build_windows'] == 'false'
                    assert fields['publish_oss'] == ('true' if event == 'workflow_dispatch' and publish == oss == 'true' else 'false')
                    assert fields['publish'] == ('true' if event == 'push' or publish == 'true' else 'false')
    assert "inputs.dry_run && 'dryrun' || 'production'" in workflow['concurrency']['group']
    assert workflow['jobs']['oss-upload']['concurrency']['group'] == "${{ github.event_name == 'workflow_dispatch' && inputs.dry_run && 'bhe-dryrun-update-channel-v1' || 'bhe-production-update-channel-v1' }}"


def test_publication_status_uses_actual_script_output(tmp_path):
    for filename in ('release-packages.yml', 'upload-release-assets-oss.yml'):
        workflow = yaml.safe_load((ROOT / '.github/workflows' / filename).read_text())
        job = workflow['jobs']['oss-upload' if filename.startswith('release-') else 'upload']
        assert job['outputs']['publish_status'] == '${{ steps.publish.outputs.status }}'
        script = workflow['jobs']['publication-status']['steps'][0]['run']
        for outcome, status, expected in [('success','dry-run-ok','演练完成 dry-run-ok'),
                                          ('success','','演练未执行'), ('skipped','','演练未执行'),
                                          ('failure','','演练失败'), ('cancelled','','演练取消')]:
            target = tmp_path / 'status'
            target.write_text('')
            env = dict(os.environ, OUTCOME=outcome, PUBLISH_STATUS=status, DRY_RUN='true', PLAN_OUTCOME='success', FAILURE_STAGE='publish', GITHUB_STEP_SUMMARY=str(target))
            subprocess.run(['bash', '-euo', 'pipefail', '-c', script], env=env, check=True)
            assert expected in target.read_text()
            assert 'dry-run-ok 不代表正式发布成功' in target.read_text()


def test_top_level_group_prefixes_separate_all_tags_case_insensitively():
    workflow = yaml.safe_load((ROOT / '.github/workflows/release-packages.yml').read_text())
    expression = workflow['concurrency']['group']
    assert expression == "desktop-release-${{ github.event_name == 'workflow_dispatch' && inputs.dry_run && 'dryrun' || 'production' }}-${{ github.event_name == 'workflow_dispatch' && inputs.tag || github.ref_name }}"
    def group(tag, event, dry):
        kind = 'dryrun' if event == 'workflow_dispatch' and dry else 'production'
        return f'desktop-release-{kind}-{tag}'
    assert group('v0.1.13', 'workflow_dispatch', True) == 'desktop-release-dryrun-v0.1.13'
    assert group('v0.1.13-dryrun', 'workflow_dispatch', False) == 'desktop-release-production-v0.1.13-dryrun'
    assert group('v0.1.13', 'push', True) == 'desktop-release-production-v0.1.13'
    assert group('V0.1.13', 'workflow_dispatch', True).casefold() == group('v0.1.13', 'workflow_dispatch', True).casefold()
    tags = ['v0.1.13', 'V0.1.13', 'v0.1.13-dryrun', 'v0.1.14']
    assert not ({group(t, 'workflow_dispatch', True).casefold() for t in tags} &
                {group(t, 'workflow_dispatch', False).casefold() for t in tags})
    assert group(tags[0], 'workflow_dispatch', True).casefold() != group(tags[-1], 'workflow_dispatch', True).casefold()
    for path in (ROOT / '.github/workflows').glob('*.yml'):
        if path.name == 'release-packages.yml': continue
        other = yaml.safe_load(path.read_text())
        assert 'desktop-release-' not in str(other.get('concurrency', {}))
        assert all('desktop-release-' not in str(job.get('concurrency', {})) for job in other['jobs'].values())


def test_credentials_steps_are_gated_and_no_secrets_leak(tmp_path):
    secrets = ['fake-key-first-ABC', 'fake-key-second-XYZ', 'fake-access-123', 'fake-secret-456', 'fake-token-789']
    for filename in ('release-packages.yml', 'upload-release-assets-oss.yml'):
        workflow = yaml.safe_load((ROOT / '.github/workflows' / filename).read_text())
        job = workflow['jobs']['oss-upload' if filename.startswith('release-') else 'upload']
        guard = "${{ !(github.event_name == 'workflow_dispatch' && inputs.dry_run) }}" if filename.startswith('release-') else "${{ toJSON(inputs.dry_run) == 'false' }}"
        for name in ('Configure Alibaba Cloud credentials', 'Install ossutil', 'Configure ossutil credentials'):
            assert next(s for s in job['steps'] if s.get('name') == name)['if'] == guard
        config = next(s['run'] for s in job['steps'] if s.get('name') == 'Configure ossutil credentials')
        publish = next(s['run'] for s in job['steps'] if s.get('name') == 'Publish verified update channel')
        base = tmp_path / filename
        base.mkdir()
        for binary, body in [('ossutil', 'exit 0'), ('python3', 'if [[ "$FAIL" == true && "$1" != -c ]]; then exit 1; fi; if [[ "$1" == -c ]]; then echo status=dry-run-ok; else printf "%s\\n" "$@" > "$ARG_LOG"; fi')]:
            p = base / binary; p.write_text('#!/bin/bash\n' + body + '\n'); p.chmod(0o755)
        for dry in ('true', 'false'):
            for fail in ('true', 'false'):
                for debug in (False, True):
                    env = dict(os.environ, PATH=str(base)+':'+os.environ['PATH'], RUNNER_TEMP=str(base),
                               UPDATE_SIGNING_KEY=secrets[0]+'\n'+secrets[1], ALIBABA_CLOUD_ACCESS_KEY_ID=secrets[2],
                               ALIBABA_CLOUD_ACCESS_KEY_SECRET=secrets[3], ALIBABA_CLOUD_SECURITY_TOKEN=secrets[4],
                               OSS_ENDPOINT='fake', TAG_NAME='v0.1.13', RELEASE_PLATFORM='all', OSS_BUCKET='oss://fake',
                               OSS_PREFIX='releases', OSS_ANDROID_KEY='android/latest.apk', DRY_RUN=dry, FAIL=fail,
                               ARG_LOG=str(base/'args'), GITHUB_OUTPUT=str(base/'output'))
                    command = ['bash', '-x' if debug else '-e', '-c']
                    results = []
                    if dry == 'false': results.append(subprocess.run(command+[config], env=env, capture_output=True, text=True))
                    results.append(subprocess.run(command+[publish], env=env, capture_output=True, text=True))
                    assert (results[-1].returncode != 0) == (fail == 'true')
                    for result in results:
                        assert all(secret not in result.stdout + result.stderr for secret in secrets)
                    args = (base/'args').read_text() if fail == 'false' else ''
                    if args:
                        assert ('--oss-config' in args) == (dry == 'false')
                    assert not (base/'bhe-update-signing-key.pem').exists()
                    assert not (base/'bhe-ossutilconfig').exists()


def test_plan_rejection_is_reported_with_stage(tmp_path):
    workflow = yaml.safe_load((ROOT / '.github/workflows/release-packages.yml').read_text())
    script = workflow['jobs']['publication-status']['steps'][0]['run']
    target = tmp_path / 'summary'
    env = dict(os.environ, OUTCOME='skipped', PLAN_OUTCOME='failure', PUBLISH_STATUS='', FAILURE_STAGE='', DRY_RUN='true', GITHUB_STEP_SUMMARY=str(target))
    subprocess.run(['bash', '-euo', 'pipefail', '-c', script], env=env, check=True)
    text = target.read_text()
    assert '计划阶段拒绝' in text and '计划阶段：failure' in text
    assert '反映的是读取当时的通道状态' in text


def test_report_identifies_failed_build_and_publish_stage(tmp_path):
    workflow = yaml.safe_load((ROOT / '.github/workflows/release-packages.yml').read_text())
    status = workflow['jobs']['publication-status']['steps'][0]['run']
    target = tmp_path / 'summary'
    env = dict(os.environ, DRY_RUN='true', PLAN_OUTCOME='success', OUTCOME='skipped', PUBLISH_STATUS='',
               FAILURE_STAGE='', MACOS_OUTCOME='skipped', WINDOWS_OUTCOME='skipped', ANDROID_OUTCOME='failure',
               RELEASE_OUTCOME='skipped', GITHUB_STEP_SUMMARY=str(target))
    subprocess.run(['bash', '-euo', 'pipefail', '-c', status], env=env, check=True)
    assert '演练未执行' in target.read_text() and '失败阶段：android' in target.read_text()
    stage_script = next(s['run'] for s in workflow['jobs']['oss-upload']['steps'] if s.get('id') == 'failure_stage')
    output = tmp_path / 'output'
    env = dict(os.environ, CHECKOUT_PUBLISHER='success', CHECKOUT_SOURCE='success', CREDENTIALS='skipped',
               INSTALL='skipped', DOWNLOAD_RELEASE='skipped', DOWNLOAD_BUILD='success', CONFIG='skipped',
               PUBLISH='failure', BACKUP='success', GITHUB_OUTPUT=str(output))
    subprocess.run(['bash', '-euo', 'pipefail', '-c', stage_script], env=env, check=True)
    assert output.read_text().strip() == 'stage=publish'


def test_tag_push_cannot_enter_oss_job_and_still_uploads_release():
    workflow = yaml.safe_load((ROOT / '.github/workflows/release-packages.yml').read_text())
    assert workflow['jobs']['oss-upload']['if'].strip() == "${{ always() && github.event_name == 'workflow_dispatch' && needs.release.result == 'success' && needs.release-plan.outputs.publish_oss == 'true' }}"
    release = workflow['jobs']['release']
    assert "needs.release-plan.outputs.publish == 'true'" in release['if']
    upload = next(step for step in release['steps'] if step.get('name') == 'Publish GitHub Release')
    assert upload['if'] == "${{ !(github.event_name == 'workflow_dispatch' && inputs.dry_run) }}"


def test_manual_release_asset_download_patterns_and_lock(tmp_path):
    workflow = yaml.safe_load((ROOT / '.github/workflows/upload-release-assets-oss.yml').read_text())
    inputs = workflow[True]['workflow_dispatch']['inputs']
    assert inputs['dry_run']['type'] == 'boolean' and inputs['dry_run']['default'] is True
    assert inputs['platform']['options'] == ['all', 'macos', 'windows', 'android']
    job = workflow['jobs']['upload']
    assert job['concurrency']['group'] == "${{ toJSON(inputs.dry_run) == 'false' && 'bhe-production-update-channel-v1' || 'bhe-dryrun-update-channel-v1' }}"
    download = next(step for step in job['steps'] if step.get('name') == 'Download exact release assets')['run']
    fake_gh = tmp_path / 'gh'
    fake_gh.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$ARG_LOG"\n')
    fake_gh.chmod(0o755)
    for platform, tag, patterns in [
        ('all', 'v0.1.13', ['BHE-*.dmg', 'BHE-*.dmg.sha256', 'BHE-*.zip', 'BHE-*.zip.sha256', 'BHE-*.apk', 'BHE-*.apk.sha256']),
        ('macos', 'v0.1.13-macos.1', ['BHE-macos-*.dmg', 'BHE-macos-*.dmg.sha256']),
        ('windows', 'v0.1.13-windows.1', ['BHE-windows-*.zip', 'BHE-windows-*.zip.sha256']),
        ('android', 'v0.1.13-android.1', ['BHE-android-*.apk', 'BHE-android-*.apk.sha256']),
    ]:
        arglog = tmp_path / (platform + '.args')
        env = dict(os.environ, PATH=str(tmp_path)+':'+os.environ['PATH'], RUNNER_TEMP=str(tmp_path),
                   TAG_NAME=tag, RELEASE_PLATFORM=platform, GITHUB_REPOSITORY='test/repo', ARG_LOG=str(arglog))
        subprocess.run(['bash', '-euo', 'pipefail', '-c', download], env=env, check=True)
        args = arglog.read_text().splitlines()
        assert args[:3] == ['release', 'download', tag]
        assert args[args.index('--repo') + 1] == 'test/repo'
        assert [args[i+1] for i, arg in enumerate(args) if arg == '--pattern'] == patterns


def test_manual_missing_input_defaults_to_dry_run_through_every_gate(tmp_path):
    import json
    primary = yaml.safe_load((ROOT / '.github/workflows/release-packages.yml').read_text())
    workflow = yaml.safe_load((ROOT / '.github/workflows/upload-release-assets-oss.yml').read_text())
    assert primary[True]['workflow_dispatch']['inputs']['dry_run']['default'] is False
    input_def = workflow[True]['workflow_dispatch']['inputs']['dry_run']
    assert input_def['default'] is True and '正式发布请显式选 false' in input_def['description']
    job = workflow['jobs']['upload']
    guard = "${{ toJSON(inputs.dry_run) == 'false' }}"
    assert job['concurrency']['group'] == "${{ toJSON(inputs.dry_run) == 'false' && 'bhe-production-update-channel-v1' || 'bhe-dryrun-update-channel-v1' }}"
    env_expression = "${{ toJSON(inputs.dry_run) == 'false' && 'false' || 'true' }}"
    assert job['env']['DRY_RUN'] == env_expression
    assert workflow['jobs']['publication-status']['steps'][0]['env']['DRY_RUN'] == env_expression
    for name in ('Configure Alibaba Cloud credentials', 'Install ossutil', 'Configure ossutil credentials'):
        assert next(s for s in job['steps'] if s.get('name') == name)['if'] == guard
    script = next(s['run'] for s in job['steps'] if s.get('name') == 'Publish verified update channel')
    fake_python = tmp_path / 'python3'
    fake_python.write_text('#!/bin/bash\nif [[ "$1" == -c ]]; then echo status=dry-run-ok; else printf "%s\\n" "$@" > "$ARG_LOG"; fi\n')
    fake_python.chmod(0o755)
    for value in (None, True, False, '', 'false', 0):
        # toJSON returns JSON text; only the boolean false serializes to unquoted false.
        production = json.dumps(value, separators=(',', ':')) == 'false'
        dry = 'false' if production else 'true'
        arglog = tmp_path / ('args-' + str(value))
        env = dict(os.environ, PATH=str(tmp_path)+':'+os.environ['PATH'], RUNNER_TEMP=str(tmp_path),
                   UPDATE_SIGNING_KEY='fake', TAG_NAME='v0.1.13', RELEASE_PLATFORM='all', OSS_BUCKET='oss://fake',
                   OSS_PREFIX='releases', OSS_ANDROID_KEY='android/latest.apk', DRY_RUN=dry, ARG_LOG=str(arglog),
                   GITHUB_OUTPUT=str(tmp_path / 'output'))
        subprocess.run(['bash', '-euo', 'pipefail', '-c', script], env=env, check=True)
        args = arglog.read_text().splitlines()
        assert ('--dry-run' in args) is not production
        assert ('--oss-config' in args) is production
