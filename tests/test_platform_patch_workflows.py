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
    assert 'publish_oss=false ;;' not in (ROOT / '.github/workflows/release-packages.yml').read_text()


def test_release_plan_platform_and_oss_controls(tmp_path):
    workflow = yaml.safe_load((ROOT / '.github/workflows/release-packages.yml').read_text())
    script = workflow['jobs']['release-plan']['steps'][0]['run']
    subprocess.run(['bash', '-n'], input=script, text=True, check=True)
    for event, tag, platform, publish, oss, expected in [
        ('push', 'v0.1.13-android.1', '', '', '', 'true'),
        ('push', 'v0.1.13-macos.1', '', '', '', 'true'),
        ('push', 'v0.1.13-windows.1', '', '', '', 'true'),
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
        assert input_def['type'] == 'boolean' and input_def['default'] is False
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
                    assert fields['publish_oss'] == ('true' if event == 'push' or (publish == oss == 'true') else 'false')
    assert "inputs.dry_run && '-dryrun'" in workflow['concurrency']['group']
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
            env = dict(os.environ, OUTCOME=outcome, PUBLISH_STATUS=status, DRY_RUN='true', GITHUB_STEP_SUMMARY=str(target))
            subprocess.run(['bash', '-euo', 'pipefail', '-c', script], env=env, check=True)
            assert expected in target.read_text()
            assert 'dry-run-ok 不代表正式发布成功' in target.read_text()
