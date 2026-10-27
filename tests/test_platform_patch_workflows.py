from pathlib import Path
import os
import subprocess

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_production_writers_share_one_lock_and_one_publishing_script():
    primary = yaml.safe_load((ROOT / '.github/workflows/release-packages.yml').read_text())
    manual = yaml.safe_load((ROOT / '.github/workflows/upload-release-assets-oss.yml').read_text())
    jobs = [primary['jobs']['oss-upload'], manual['jobs']['upload']]
    expected = {'group': 'bhe-production-update-channel-v1', 'cancel-in-progress': False}
    for job in jobs:
        assert job['concurrency'] == expected
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
                   INPUT_PLATFORM=platform, INPUT_PUBLISH=publish, INPUT_PUBLISH_OSS=oss,
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
