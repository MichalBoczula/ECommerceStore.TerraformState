import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE_AZ = r'''#!/usr/bin/env python3
import json, os, sys
args=sys.argv[1:]
with open(os.environ['AZ_CALLS'],'a') as f: f.write(json.dumps(args)+'\n')
def scalar(value):
    print(value, end='\r\n' if os.environ.get('WINDOWS_OUTPUT') else '\n')
if args[:2] == ['account','show']:
    scalar('33333333-3333-3333-3333-333333333333')
elif args[:3] == ['storage','account','show']:
    if '--output' in args and args[args.index('--output')+1]=='none':
        sys.exit(0 if os.environ.get('ACCOUNT_EXISTS','1')=='1' else 1)
    print(json.dumps({'kind':'StorageV2','sku':{'name':'Standard_LRS'},
        'enableHttpsTrafficOnly':True,'minimumTlsVersion':'TLS1_2',
        'allowSharedKeyAccess':False,'allowBlobPublicAccess':False,'publicNetworkAccess':'Enabled'}))
elif args[:3] == ['ad','signed-in-user','show']:
    scalar('44444444-4444-4444-4444-444444444444')
elif args[:3] == ['role','assignment','list']:
    scalar(os.environ.get('ROLE_COUNT','1'))
elif args[:3] == ['storage','container','create'] and os.environ.get('FAIL_CONTAINER'):
    sys.exit(1)
'''


class ExternalStateSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name)
        (self.root/'scripts').mkdir()
        shutil.copy(ROOT/'scripts/prepare-state.sh',self.root/'scripts')
        bin_dir=self.root/'bin';bin_dir.mkdir()
        tool=bin_dir/'az';tool.write_text(FAKE_AZ);tool.chmod(0o700)
        self.env=dict(os.environ,PATH=str(bin_dir)+os.pathsep+os.environ['PATH'],
            ECOM_STATE_SUBSCRIPTION='33333333-3333-3333-3333-333333333333',
            ECOM_STATE_ACCOUNT='stecomtfmocktest',ECOM_STATE_GROUP='rg-ecommerce-terraform-state',
            ECOM_STATE_LOCATION='northeurope',AZ_CALLS=str(self.root/'calls.jsonl'))

    def tearDown(self):
        self.temp.cleanup()

    def run_script(self):
        return subprocess.run(['bash',str(self.root/'scripts/prepare-state.sh')],
                              env=self.env,capture_output=True,text=True)

    def calls(self):
        file=self.root/'calls.jsonl'
        return [json.loads(line) for line in file.read_text().splitlines()] if file.exists() else []

    def test_existing_store_is_not_recreated_and_state_is_remote(self):
        result=self.run_script()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(any(c[:3]==['storage','account','create'] for c in self.calls()))
        containers=[c for c in self.calls() if c[:3]==['storage','container','create']]
        self.assertEqual(len(containers),2)
        self.assertTrue(all('--auth-mode' in c and 'login' in c for c in containers))
        self.assertIn('container_name = "bootstrap-state"',(self.root/'backend.hcl').read_text())
        self.assertFalse(list(self.root.glob('*.tfstate*')))
        self.assertEqual(self.run_script().returncode,0,'External setup must be repeatable')

    def test_new_store_uses_authenticated_private_access(self):
        self.env['ACCOUNT_EXISTS']='0'
        result=self.run_script()
        self.assertEqual(result.returncode,0,result.stderr)
        create=next(c for c in self.calls() if c[:3]==['storage','account','create'])
        self.assertEqual(create[create.index('--allow-shared-key-access')+1],'false')
        self.assertEqual(create[create.index('--allow-blob-public-access')+1],'false')
        self.assertEqual(create[create.index('--sku')+1],'Standard_LRS')

    def test_configuration_conflict_stops_before_azure_calls(self):
        (self.root/'bootstrap.auto.tfvars.json').write_text(json.dumps({'subscription_id':'different'}))
        self.assertNotEqual(self.run_script().returncode,0)
        self.assertEqual(self.calls(),[])

    def test_container_failure_cannot_report_success(self):
        self.env['FAIL_CONTAINER']='1'
        result=self.run_script()
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.root/'backend.hcl').exists())
        self.assertNotIn('Independent state store ready',result.stdout)

    def test_windows_cli_and_python_output_are_normalized(self):
        self.env['WINDOWS_OUTPUT']='1'
        self.env['ROLE_COUNT']='0'
        self.env.pop('ECOM_STATE_SUBSCRIPTION')
        self.env.pop('ECOM_STATE_ACCOUNT')
        # Simulate Windows Python stdout as well as Azure CLI stdout.
        tool=self.root/'bin'/'python3'
        tool.write_text('#!'+sys.executable+'\n'
            'import subprocess, sys\n'
            'result=subprocess.run([sys.executable,*sys.argv[1:]],stdout=subprocess.PIPE)\n'
            'sys.stdout.buffer.write(result.stdout.replace(b"\\r\\n",b"\\n").replace(b"\\n",b"\\r\\n"))\n'
            'sys.exit(result.returncode)\n')
        tool.chmod(0o700)
        result=self.run_script()
        self.assertEqual(result.returncode,0,result.stderr)
        values=json.loads((self.root/'bootstrap.auto.tfvars.json').read_text())
        subscription='33333333-3333-3333-3333-333333333333'
        self.assertEqual(values['subscription_id'],subscription)
        self.assertEqual(values['state_storage_account_name'],
            'stecomtf'+hashlib.sha256(subscription.encode()).hexdigest()[:14])
        self.assertTrue(all('\r' not in value for call in self.calls() for value in call))
        assignment=next(c for c in self.calls() if c[:3]==['role','assignment','create'])
        self.assertEqual(assignment[assignment.index('--assignee-object-id')+1],
            '44444444-4444-4444-4444-444444444444')
