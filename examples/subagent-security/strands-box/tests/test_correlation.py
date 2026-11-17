#!/usr/bin/env python3
"""Exercise the real sample correlator with synthetic accepted and rejected receipts.

These fixtures are verifier inputs, not evidence of a model call or cluster deployment.
Run from any directory: python3 examples/subagent-security/strands-box/tests/test_correlation.py
All disposable files remain under this repository's ignored tmp/ directory.
"""
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import contextlib
import io
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
from types import SimpleNamespace
import copy
import json
from pathlib import Path

AVAILABILITY = json.loads((Path(__file__).resolve().parents[4] / 'examples/subagent-security/analyst/fixtures/availability.json').read_text())
RUN_ID = 'a' * 32
DRAFT = '/cases/rfp-001/recommendations'
SUPPLIERS = '/cases/rfp-001/suppliers'

def receipts(mode='cloud'):
    operations = [
        ('reader-get','reader','GET',SUPPLIERS,200,'supplier_read_case'),
        ('reader-post','reader','POST',DRAFT,403,'default_deny'),
        ('reader-patch','reader','PATCH','/suppliers/northstar',403,'default_deny'),
        ('reader-order','reader','POST','/purchase-orders',403,'default_deny'),
        ('reader-other-case','reader','GET','/cases/rfp-other/suppliers',403,'default_deny'),
        ('evaluator-get','evaluator','GET',SUPPLIERS,403,'default_deny'),
        ('writer-get','writer','GET',SUPPLIERS,200,'supplier_read_case'),
        ('writer-patch','writer','PATCH','/suppliers/northstar',403,'default_deny'),
        ('writer-order','writer','POST','/purchase-orders',403,'default_deny'),
        ('writer-other-case','writer','GET','/cases/rfp-other/suppliers',403,'default_deny'),
        ('writer-draft-1','writer','POST',DRAFT,201,'supplier_draft'),
        ('writer-draft-2','writer','POST',DRAFT,201,'supplier_draft'),
        ('writer-draft-3','writer','POST',DRAFT,201,'supplier_draft'),
        ('writer-draft-4','writer','POST',DRAFT,403,'draft_response_budget'),
        ('fresh-writer-draft','writer','POST',DRAFT,201,'supplier_draft'),
        ('control-draft',None,'POST',DRAFT,201,None),
        ('control-patch',None,'PATCH','/suppliers/northstar',200,None),
        ('control-order',None,'POST','/purchase-orders',200,None),
        ('control-other-case',None,'GET','/cases/rfp-other/suppliers',200,None),
    ]
    operations += [(label+'-'+target,'writer' if label=='fresh-writer' else label,'GET',SUPPLIERS,403,'default_deny')
                   for label in ('reader','evaluator','writer','fresh-writer') for target in ('alias','unknown')]
    operations.append(('control-alias',None,'GET',SUPPLIERS,200,None))
    calls,upstream=[],[]
    for index,(name,role,method,path,status,rule) in enumerate(operations):
        request_id=RUN_ID+'-'+name
        call={'request_id':request_id,'method':method,'path':path,
              'expected_status':status,'actual_status':status}
        host='localhost' if name.endswith('-alias') else 'not-approved.invalid' if name.endswith('-unknown') else '127.0.0.1'
        call.update(host=host, port=12345)
        if role is None:call.update(control=True,call_id=request_id)
        else:
            action='net:connect' if role=='evaluator' or host!='127.0.0.1' else 'http:request'
            owner='fresh-writer' if name.startswith('fresh-writer-') else role
            call.update(role=role,host=host,port=12345,action='api',started_ns=1_000_000_000+100*index,
                        ended_ns=1_000_000_050+100*index,config_sha256='b'*64,policy_sha256='c'*64)
            call.update(call_id=RUN_ID+'-'+owner+'-'+name, box_id='box-'+owner, box_run_id='run-'+owner)
            call['box_decisions']=[{
                'strands.box.policy.principal':'agent:self',
                'strands.box.policy.action':action,'strands.box.policy.verdict':'deny' if status==403 else 'permit',
                'strands.box.policy.resource':host+':12345'+(path if action=='http:request' else ''),
                'strands.box.policy.rule':rule,'server.address':host,'server.port':12345,
                'http.request.method':method,'strands.box.request.id':str(index),
                'box_run_id':'run-'+owner,'box_id':'box-'+owner,
                'timestamp_ns':1_000_000_020+100*index}]
            if action=='http:request':
                connection=copy.deepcopy(call['box_decisions'][0])
                connection.update({'strands.box.policy.action':'net:connect','strands.box.policy.verdict':'permit',
                                   'strands.box.policy.resource':host+':12345','strands.box.policy.rule':'supplier_connect',
                                   'timestamp_ns':connection['timestamp_ns']-1})
                connection.pop('http.request.method',None)
                call['box_decisions'].insert(0,connection)
        if status == 403:
            body = 'Synthetic policy denial'
        elif method == 'GET':
            body = {'case_id':path.split('/')[2],'availability':copy.deepcopy(AVAILABILITY)}
        elif path == DRAFT:
            body = {'saved':True,'request_id':request_id}
        else:
            body = {'synthetic_mutation_accepted':True,'request_id':request_id}
        call['result']={'status':status,'body':body}
        if status!=403:
            upstream.append({'request_id':request_id,'method':method,'path':path})
        calls.append(call)
    for label in ('reader','evaluator','writer','fresh-writer'):
        role='writer' if label=='fresh-writer' else label
        probes=[('credential_names','credential-names',{'aws_credential_names':[],'model_key_names':[],'supplier_key_present':False}),
                ('direct_supplier_connection','connect',{'native_connect_error_errno':111})]
        if mode=='cloud':
            probes += [('pod_identity_token','readable',{'access_error_errno':2}),
                       ('direct_pod_identity_connection','connect',{'native_connect_error_errno':101})]
        for name,action,result in probes:
            call={'call_id':RUN_ID+'-'+label+'-'+name,'role':role,'action':action,'result':result,
                  'box_id':'box-'+label,'box_run_id':'run-'+label,'config_sha256':'b'*64,'policy_sha256':'c'*64}
            if action=='connect':call['native_target']={'host':'192.0.2.10','port':12345,'controller_connected':True}
            calls.append(call)
    evidence={'run_id':RUN_ID,'mode':mode,'completed':True,'case_id':'rfp-001',
              'comparison':{'recommended_supplier':'northstar'},'model_usage':{'totalTokens':1} if mode=='cloud' else None,
              'checks':workflow_receipts(mode), 'box_sha256':'d'*64, 'architecture':'aarch64','kernel':'synthetic-kernel',
              'aws_arn':'arn:aws:sts::000000000000:assumed-role/sample-analyst/synthetic-session' if mode=='cloud' else None,
              'report_prefix':'reports/rfp-001/'+RUN_ID if mode=='cloud' else None,
              'calls':calls,'supplier_origin':{'scheme':'http','host':'127.0.0.1','port':12345},
              'supplier_alias_origin':{'scheme':'http','host':'localhost','port':12345}}
    return evidence,upstream

def write_receipts(folder, mode='cloud'):
    folder=Path(folder);folder.mkdir(exist_ok=True)
    evidence,upstream=receipts(mode)
    for name,data in [('evidence',evidence),('checks',evidence['checks']),('calls',evidence['calls'])]:
        (folder/(name+'.json')).write_text(json.dumps(data)+'\n')
    for name,rows in [('supplier-api-requests',upstream)]:
        (folder/(name+'.jsonl')).write_text(''.join(json.dumps(row)+'\n' for row in rows))
    rewrite_records(folder, evidence)
    for label in ('reader','evaluator','writer','fresh-writer'):
        (folder/'broker'/label/'box-identity.json').write_text(json.dumps({
            'box_id':'box-'+label,'box_run_id':'run-'+label,'committed_record_sha256':'e'*64}))
    (folder/'recommendation.md').write_text('Synthetic offline receipt fixture.\n')
    (folder/'filesystem-checks.json').write_text(json.dumps(filesystem_receipt(evidence)))
    (folder/'deployment.json').write_text(json.dumps({'target_environment':{'ANALYST_ROLE_NAME':'sample-analyst'}}))


def rewrite_records(folder, evidence):
    """Preserve exact raw-log consistency when testing altered call identities."""
    for label in ('reader','evaluator','writer','fresh-writer'):
        broker=folder/'broker'/label;broker.mkdir(parents=True,exist_ok=True)
        records=[]
        for call in evidence['calls']:
            for event in call.get('box_decisions',[]):
                if event['box_id']!='box-'+label:continue
                value=lambda x:{'intValue':str(x)} if type(x) is int else {'stringValue':x}
                fields=[{'key':key,'value':value(item)} for key,item in event.items()
                        if key not in ('box_run_id','box_id','timestamp_ns')]
                record={'resourceLogs':[{'resource':{'attributes':[
                    {'key':'strands.box.run.id','value':value(event['box_run_id'])},
                    {'key':'strands.box.name','value':value(event['box_id'])}]},
                    'scopeLogs':[{'scope':{'name':'strands-box.policy'},'logRecords':[
                        {'eventName':'strands.box.policy.decision','timeUnixNano':str(event['timestamp_ns']),
                         'attributes':fields}]}]}]}
                records.append(record)
        (broker/'box-records.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in records))


FILESYSTEM_NAMES = (
    "unconfined reads and writes succeed", "every probe produced one result",
    "own_input_read", "own_output_read", "own_output_write", "output file confirmed by controller",
    "shared supplier comparison", "sibling_input_read refused", "sibling_output_write refused",
    "input_write refused", "configuration_write refused", "policy_write refused", "state_write refused",
    "protected files unchanged", "Box state exists", "worker did not change Box state",
    "controller can write Box state",
)


def workflow_receipts(mode):
    names = ["standalone native filesystem checks passed", "each role has a distinct Box identity",
             "controller can open protected credential files", "controller can reach direct_supplier_connection",
             "reader reads its staged case", "supplier availability belongs to the assigned case",
             "offline evaluator agrees with controller arithmetic", "eligible supplier is northstar",
             "writer output matches verified comparison",
             "reader, evaluator, writer and fresh writer have distinct Box identities"]
    names += [role+": "+name for role in ("reader", "evaluator", "writer") for name in FILESYSTEM_NAMES]
    if mode == "cloud":
        names += ["AWS uses the Pod Identity container provider", "AWS caller is the sample role",
                  "controller has no model API key", "S3 case matches shared fixtures",
                  "S3 proposal matches case: northstar", "S3 proposal matches case: harbor", "S3 proposal matches case: cedar",
                  "IAM refuses put_object proposals/rfp-001/case.json", "IAM refuses delete_object proposals/rfp-001/case.json",
                  "IAM refuses get_object proposals/rfp-other/case.json", "controller can reach direct_pod_identity_connection",
                  "model called the evidence tool", "Bedrock returned nonzero token usage",
                  "model choice matches verified comparison", "model cites all shared proposal sources",
                  "choice gate rejects an ineligible supplier", "citation gate rejects a missing source",
                  "S3 round trip: recommendation.md", "S3 round trip: comparison.json"]
    return [{"name": name, "passed": True} for name in names]


def filesystem_receipt(evidence):
    roles = {}
    for role in ("reader", "evaluator", "writer"):
        values = {"own_input_read": {"role": role}, "own_output_read": {"role": role},
                  "own_output_write": {"written": "/synthetic/"+role+"/out/result.json"},
                  "comparison": evidence["comparison"]}
        values.update({name: {"access_error_errno": 13} for name in
                       ("sibling_input_read", "sibling_output_write", "input_write", "configuration_write", "policy_write", "state_write")})
        roles[role] = {"box_dir": "/synthetic/broker/"+role+"/state", "config_sha256": "b"*64, "policy_sha256": "c"*64,
                       "results": [{"name": name, "result": result} for name, result in values.items()]}
    names = {role+": "+name for role in roles for name in FILESYSTEM_NAMES} | {"each role has a distinct Box identity"}
    return {"stage": "filesystem", "passed": True, "uid": 1000,
            "box_sha256": evidence["box_sha256"], "architecture": evidence["architecture"], "kernel": evidence["kernel"],
            "checks": [row for row in evidence["checks"] if row["name"] in names], "roles": roles}


REPO = Path(__file__).resolve().parents[4]
CORRELATOR = REPO / "examples/subagent-security/strands-box/scripts/correlate.py"


class CorrelationTests(unittest.TestCase):
    def setUp(self):
        (REPO / "tmp").mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(prefix="box-correlation-test-", dir=REPO / "tmp")
        self.addCleanup(self.scratch.cleanup)
        self.folder = Path(self.scratch.name)
        write_receipts(self.folder)

    def edit(self, filename, mutation):
        path = self.folder / filename
        value = json.loads(path.read_text())
        mutation(value)
        path.write_text(json.dumps(value))
        if filename == "evidence.json":
            for name in ("checks", "calls"):
                (self.folder / (name+".json")).write_text(json.dumps(value[name]))

    def run_check(self, *, accepted=False, cloud=True):
        command = [sys.executable, "-B", str(CORRELATOR)]
        if cloud:
            command.append("--require-cloud")
        command += [str(self.folder / name) for name in
                    ("evidence.json", "supplier-api-requests.jsonl")]
        result = subprocess.run(command, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0 if accepted else 1, result.stdout+result.stderr)
        if not accepted:
            self.assertTrue(result.stderr.startswith("ERROR: "), result.stdout+result.stderr)
            self.assertNotIn("Traceback", result.stderr)
        return result

    def test_complete_cloud_receipts_pass(self):
        self.run_check(accepted=True)

    def test_complete_local_receipts_pass_only_without_cloud_requirement(self):
        write_receipts(self.folder, mode="local")
        self.run_check(accepted=True, cloud=False)
        self.run_check()

    def test_unrelated_passing_check_cannot_replace_workflow_gates(self):
        self.edit("evidence.json", lambda value: value.update(checks=[{"name": "unrelated", "passed": True}]))
        self.assertIn("required check receipts", self.run_check().stderr)

    def test_each_required_gate_is_required(self):
        original = json.loads((self.folder / "evidence.json").read_text())
        for check in original["checks"]:
            with self.subTest(check=check["name"]):
                write_receipts(self.folder)
                self.edit("evidence.json", lambda value: value.update(checks=[row for row in value["checks"] if row["name"] != check["name"]]))
                self.run_check()

    def test_failed_or_duplicate_check_is_rejected(self):
        self.edit("evidence.json", lambda value: value["checks"][0].update(passed=False))
        self.run_check()
        write_receipts(self.folder)
        self.edit("evidence.json", lambda value: value["checks"].append(value["checks"][0]))
        self.run_check()

    def test_missing_supporting_receipts_are_rejected(self):
        for name in ("filesystem-checks.json", "deployment.json", "broker/reader/box-identity.json", "broker/writer/box-records.jsonl"):
            with self.subTest(file=name):
                write_receipts(self.folder)
                (self.folder / name).rename(self.folder / "withheld.json")
                self.run_check()
                (self.folder / "withheld.json").rename(self.folder / name)

    def test_aws_identity_and_report_prefix_are_required(self):
        for name in ("aws_arn", "report_prefix"):
            with self.subTest(field=name):
                write_receipts(self.folder)
                self.edit("evidence.json", lambda value: value.pop(name))
                self.run_check()
        write_receipts(self.folder)
        self.edit("deployment.json", lambda value: value["target_environment"].update(ANALYST_ROLE_NAME="different-role"))
        self.run_check()

    def test_native_filesystem_failure_is_not_hidden_by_summary(self):
        self.edit("filesystem-checks.json", lambda value: next(row for row in value["roles"]["reader"]["results"]
                  if row["name"] == "policy_write").update(result={"written": "/synthetic/policy.dw"}))
        self.assertIn("filesystem operation was not refused", self.run_check().stderr)

    def test_box_identity_receipt_must_match_role_calls(self):
        self.edit("broker/reader/box-identity.json", lambda value: value.update(box_id="different-box"))
        self.run_check()

    def test_box_decision_must_match_call_identity(self):
        self.edit("evidence.json", lambda value: value["calls"][0].update(box_id="different-box"))
        self.run_check()

    def test_method_path_and_missing_call_are_rejected(self):
        for name, replacement in (("method", "PATCH"), ("path", "/purchase-orders")):
            with self.subTest(field=name):
                write_receipts(self.folder)
                self.edit("evidence.json", lambda value: value["calls"][0].update({name: replacement}))
                self.run_check()
        write_receipts(self.folder)
        self.edit("evidence.json", lambda value: value["calls"].pop(0))
        self.run_check()

    def test_duplicate_arrival_is_rejected(self):
        path = self.folder / "supplier-api-requests.jsonl"
        path.write_text(path.read_text()+path.read_text().splitlines()[0]+"\n")
        self.run_check()

    def test_denied_request_reaching_supplier_is_rejected(self):
        path = self.folder / "supplier-api-requests.jsonl"
        path.write_text(path.read_text()+json.dumps({"request_id": RUN_ID+"-reader-post", "method": "POST", "path": DRAFT})+"\n")
        self.run_check()

    def test_worker_response_and_role_must_match_recorded_scenario(self):
        self.edit("evidence.json", lambda value: value["calls"][0]["result"].update(status=500))
        self.run_check()
        write_receipts(self.folder)
        self.edit("evidence.json", lambda value: value["calls"][0].update(role="writer"))
        self.run_check()

    def test_supplier_origin_and_alias_must_match_requested_destinations(self):
        for key in ("supplier_origin", "supplier_alias_origin"):
            with self.subTest(field=key):
                write_receipts(self.folder)
                self.edit("evidence.json", lambda value: value.pop(key))
                self.run_check()
        write_receipts(self.folder)
        self.edit("evidence.json", lambda value: value["supplier_origin"].update(host="different-supplier.invalid"))
        self.run_check()

    def test_native_probe_values_and_identities_cannot_contradict_pass_summary(self):
        mutations = (
            lambda value: value.update(uid=0),
            lambda value: value.update(box_sha256="0"*64),
            lambda value: value["roles"]["reader"].update(box_dir=value["roles"]["writer"]["box_dir"]),
            lambda value: value["roles"]["reader"]["results"].pop(0),
            lambda value: value["roles"]["reader"]["results"].append(value["roles"]["reader"]["results"][0]),
        )
        for index, mutation in enumerate(mutations):
            with self.subTest(case=index):
                write_receipts(self.folder)
                self.edit("filesystem-checks.json", mutation)
                self.run_check()

    def test_draft_temporal_rule_and_window_are_required(self):
        def change_rule(value):
            call = next(row for row in value["calls"] if row.get("request_id") == RUN_ID+"-writer-draft-4")
            call["box_decisions"][-1]["strands.box.policy.rule"] = "unrelated-rule"
        self.edit("evidence.json", change_rule)
        self.run_check()
        write_receipts(self.folder)
        def extend_window(value):
            call = next(row for row in value["calls"] if row.get("request_id") == RUN_ID+"-writer-draft-4")
            call["ended_ns"] += 601 * 1_000_000_000
        self.edit("evidence.json", extend_window)
        self.run_check()


    def scenario(self, value, name):
        return next(row for row in value["calls"] if row.get("request_id") == RUN_ID+"-"+name)

    def test_every_http_call_requires_its_fixed_identifier(self):
        original, _ = receipts()
        for row in original["calls"]:
            if "request_id" not in row:
                continue
            with self.subTest(scenario=row["request_id"]):
                write_receipts(self.folder)
                self.edit("evidence.json", lambda value: next(call for call in value["calls"]
                          if call.get("request_id") == row["request_id"]).pop("call_id"))
                self.assertIn("call identifier", self.run_check().stderr)
        write_receipts(self.folder)
        self.edit("evidence.json", lambda value: [row.pop("call_id", None) for row in value["calls"]
                  if "request_id" in row])
        self.run_check()

    def test_http_call_cannot_move_to_another_box_even_with_matching_raw_logs(self):
        for name in ("reader-patch", "writer-get", "writer-draft-1", "writer-draft-2", "writer-draft-3", "writer-draft-4"):
            for rename in (True, False):
                with self.subTest(scenario=name, renamed=rename):
                    write_receipts(self.folder)
                    def move(value):
                        row = self.scenario(value, name)
                        target = "writer" if name.startswith("reader-") else "reader"
                        if rename:
                            row["call_id"] = RUN_ID+"-"+target+"-"+name
                        row.update(box_id="box-"+target, box_run_id="run-"+target)
                        for event in row["box_decisions"]:
                            event.update(box_id="box-"+target, box_run_id="run-"+target)
                    self.edit("evidence.json", move)
                    rewrite_records(self.folder, json.loads((self.folder/"evidence.json").read_text()))
                    result = self.run_check()
                    self.assertNotIn("raw Box decision logs differ", result.stderr)

    def test_all_writer_drafts_cannot_move_together_to_reader_box(self):
        for rename in (False, True):
            with self.subTest(renamed=rename):
                write_receipts(self.folder)
                def move(value):
                    for number in range(1, 5):
                        name = "writer-draft-"+str(number)
                        row = self.scenario(value, name)
                        if rename:
                            row["call_id"] = RUN_ID+"-reader-"+name
                        row.update(box_id="box-reader", box_run_id="run-reader")
                        for event in row["box_decisions"]:
                            event.update(box_id="box-reader", box_run_id="run-reader")
                self.edit("evidence.json", move)
                rewrite_records(self.folder, json.loads((self.folder/"evidence.json").read_text()))
                expected = "role call identifier" if rename else "committed Box identity receipt"
                self.assertIn(expected, self.run_check().stderr)

    def test_successful_supplier_bodies_are_required_for_workers_and_controls(self):
        mutations = (
            ("writer-draft-1", {"saved": False}, "saved draft"),
            ("writer-draft-2", {"request_id": "another-request"}, "submitted request"),
            ("writer-draft-3", {"case_id": "rfp-other"}, "different procurement case"),
            ("fresh-writer-draft", {"saved": 1}, "saved draft"),
            ("control-draft", {"saved": False}, "saved draft"),
            ("control-draft", {"request_id": "another-request"}, "submitted request"),
            ("control-patch", {"synthetic_mutation_accepted": False}, "synthetic mutation"),
            ("control-order", {"request_id": "another-request"}, "submitted request"),
            ("reader-get", {"case_id": "rfp-other"}, "different procurement case"),
            ("writer-get", {"availability": {}}, "availability data"),
            ("control-alias", {"case_id": "rfp-other"}, "different procurement case"),
            ("control-other-case", {"case_id": "rfp-001"}, "different procurement case"),
        )
        for name, changes, message in mutations:
            with self.subTest(scenario=name, changes=changes):
                write_receipts(self.folder)
                self.edit("evidence.json", lambda value: self.scenario(value,name)["result"]["body"].update(changes))
                self.assertIn(message, self.run_check().stderr)
        for name in ("reader-get", "writer-draft-1", "control-draft", "control-order", "control-alias"):
            with self.subTest(missing_body=name):
                write_receipts(self.folder)
                self.edit("evidence.json", lambda value: self.scenario(value,name)["result"].pop("body"))
                self.run_check()

    def test_each_trusted_control_requires_primary_or_alias_origin(self):
        for name in ("control-draft", "control-patch", "control-order", "control-other-case", "control-alias"):
            for changes in ({"host":"wrong-origin.invalid"}, {"port":9}):
                with self.subTest(scenario=name, changes=changes):
                    write_receipts(self.folder)
                    self.edit("evidence.json", lambda value: self.scenario(value,name).update(changes))
                    self.assertIn("different target host or port", self.run_check().stderr)

    def test_native_denials_reject_success_fields_and_noninteger_errno(self):
        replacements = [
            {"native_connect_error_errno":111,"connected":True},
            {"native_connect_error_errno":111,"written":"/synthetic/result"},
            {"native_connect_error_errno":111,"denied_errno":13},
            {"native_connect_error_errno":True}, {"native_connect_error_errno":1.0},
            {"denied_errno":True}, {"denied_errno":111},
        ]
        for result in replacements:
            with self.subTest(result=result):
                write_receipts(self.folder)
                self.edit("evidence.json", lambda value: next(row for row in value["calls"]
                          if row.get("action") == "connect").update(result=result))
                self.assertIn("direct connection was not refused", self.run_check().stderr)
        for result in ({"native_connect_error_errno":111}, {"native_connect_error_errno":1}, {"denied_errno":13}):
            with self.subTest(valid=result):
                write_receipts(self.folder)
                self.edit("evidence.json", lambda value: next(row for row in value["calls"]
                          if row.get("action") == "connect").update(result=result))
                self.run_check(accepted=True)

    def test_filesystem_and_token_denials_reject_success_fields_and_noninteger_errno(self):
        for result in ({"access_error_errno":13,"written":"/synthetic/policy.dw"},
                       {"access_error_errno":2,"readable":True},
                       {"access_error_errno":True}, {"access_error_errno":1.0}):
            with self.subTest(result=result):
                write_receipts(self.folder)
                self.edit("filesystem-checks.json", lambda value: next(row for row in value["roles"]["reader"]["results"]
                          if row["name"] == "policy_write").update(result=result))
                self.assertIn("filesystem operation was not refused", self.run_check().stderr)
                write_receipts(self.folder)
                self.edit("evidence.json", lambda value: next(row for row in value["calls"]
                          if row.get("action") == "readable").update(result=result))
                self.assertIn("protected credential file", self.run_check().stderr)


    def test_raw_role_logs_cannot_be_swapped_or_mixed(self):
        reader = self.folder/"broker/reader/box-records.jsonl"
        writer = self.folder/"broker/writer/box-records.jsonl"
        original_reader, original_writer = reader.read_text(), writer.read_text()
        reader.write_text(original_writer)
        writer.write_text(original_reader)
        self.assertIn("reader raw Box decision log differs from its committed identity", self.run_check().stderr)
        write_receipts(self.folder)
        reader.write_text(reader.read_text()+writer.read_text().splitlines()[0]+"\n")
        self.assertIn("reader raw Box decision log differs from its committed identity", self.run_check().stderr)

    def test_each_role_log_requires_all_and_only_its_expected_decisions(self):
        path = self.folder/"broker/reader/box-records.jsonl"
        original = path.read_text()
        path.write_text("\n".join(original.splitlines()[1:])+"\n")
        self.assertIn("reader raw Box decision log differs from its role", self.run_check().stderr)
        path.write_text(original+original.splitlines()[0]+"\n")
        self.assertIn("reader raw Box decision log differs from its role", self.run_check().stderr)

    def test_duplicate_json_keys_are_rejected_at_every_receipt_input(self):
        cases = (
            ("evidence.json", '"completed": true', '"completed": false, "completed": true'),
            ("evidence.json", '"native_connect_error_errno": 111', '"native_connect_error_errno": 0, "native_connect_error_errno": 111'),
            ("calls.json", '"native_connect_error_errno": 111', '"native_connect_error_errno": 0, "native_connect_error_errno": 111'),
            ("checks.json", '"passed": true', '"passed": false, "passed": true'),
            ("filesystem-checks.json", '"access_error_errno": 13', '"access_error_errno": false, "access_error_errno": 13'),
            ("deployment.json", '"ANALYST_ROLE_NAME": "sample-analyst"', '"ANALYST_ROLE_NAME": "other", "ANALYST_ROLE_NAME": "sample-analyst"'),
            ("broker/reader/box-identity.json", '"box_id": "box-reader"', '"box_id": "other", "box_id": "box-reader"'),
            ("supplier-api-requests.jsonl", '"method": "GET"', '"method": "PATCH", "method": "GET"'),
            ("broker/reader/box-records.jsonl", '"eventName": "strands.box.policy.decision"',
             '"eventName": "other", "eventName": "strands.box.policy.decision"'),
        )
        for name, target, replacement in cases:
            with self.subTest(file=name, target=target):
                write_receipts(self.folder)
                path = self.folder/name
                before = path.read_text()
                self.assertIn(target, before)
                path.write_text(before.replace(target, replacement, 1))
                self.assertIn("Duplicate JSON object key", self.run_check().stderr)
        for filename in ("evidence.json", "calls.json"):
            path = self.folder/filename
            path.write_text(path.read_text().replace('"native_connect_error_errno": 111',
                            '"native_connect_error_errno": 0, "native_connect_error_errno": 111'))
        self.assertIn("Duplicate JSON object key", self.run_check().stderr)

    def test_duplicate_telemetry_attributes_are_rejected(self):
        for kind in ("identity", "decision"):
            with self.subTest(attributes=kind):
                write_receipts(self.folder)
                path = self.folder/"broker/reader/box-records.jsonl"
                rows = [json.loads(line) for line in path.read_text().splitlines()]
                resource = rows[0]["resourceLogs"][0]
                attributes = (resource["resource"]["attributes"] if kind == "identity"
                              else resource["scopeLogs"][0]["logRecords"][0]["attributes"])
                attributes.insert(0, copy.deepcopy(attributes[0]))
                path.write_text("".join(json.dumps(row)+"\n" for row in rows))
                self.assertIn("Duplicate JSON object key", self.run_check().stderr)


class ControllerReceiptTests(unittest.TestCase):
    """Exercise the controller paths that produce and classify the receipts."""

    @classmethod
    def setUpClass(cls):
        sys.dont_write_bytecode = True
        sys.path.insert(0, str(CORRELATOR.parent.parent / "src"))
        import controller
        cls.controller = controller

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="box-controller-test-", dir=REPO/"tmp")
        self.addCleanup(self.scratch.cleanup)
        self.folder = Path(self.scratch.name)
        self.run = self.controller.Run.__new__(self.controller.Run)
        self.run.id = RUN_ID
        self.run.root = self.folder/"run"
        (self.run.root/"reader/in").mkdir(parents=True)
        self.run.state_root = self.folder/"state"
        self.run.state_root.mkdir()
        self.run.code = self.folder
        self.run.calls, self.run.checks, self.run.box_ids = [], [], []
        self.run.supplier_url = "http://supplier.invalid:8080"
        self.run.supplier_alias_url = "http://alias.invalid:8080"
        self.run.supplier_origin = {"scheme":"http","host":"supplier.invalid","port":8080}
        self.run.native_targets = [("direct_supplier_connection","192.0.2.10",8080)]
        self.run.args = SimpleNamespace(local=False, box_binary="synthetic-box")

    def batch(self, native, token):
        names = ("credential_names", "pod_identity_token", "direct_supplier_connection", "reader-alias", "reader-unknown")
        results = ({"aws_credential_names":[], "model_key_names":[], "supplier_key_present":False}, token, native,
                   {"status":403,"body":"Synthetic denial"}, {"status":403,"body":"Synthetic denial"})
        rows = [{"name":name,"result":result,"started_ns":1,"ended_ns":3} for name,result in zip(names,results)]
        events = [{"strands.box.policy.action":"net:connect","strands.box.request.id":str(i)} for i in range(2)]
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.dict("os.environ", {"AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE":"/synthetic/token"}))
            for name, value in (("prepare", self.folder/"box.toml"), ("execute", rows),
                                ("decisions", events), ("batch_identity", ("box-reader", "run-reader")), ("sha256", "b"*64)):
                stack.enter_context(patch.object(self.controller, name, return_value=value))
            stack.enter_context(patch.object(self.controller.shutil, "copyfile"))
            stack.enter_context(patch.object(self.controller, "match", side_effect=events))
            stack.enter_context(patch.object(self.run, "dump"))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            return self.run.batch("reader", [])

    def test_batch_accepts_unambiguous_native_and_token_denials(self):
        result = self.batch({"native_connect_error_errno":111}, {"access_error_errno":2})
        self.assertEqual(result["direct_supplier_connection"], {"native_connect_error_errno":111})
        self.assertTrue(all(row["passed"] for row in self.run.checks))

    def test_batch_rejects_native_connected_plus_errno(self):
        with self.assertRaisesRegex(AssertionError, "unreachable from the native worker"):
            self.batch({"native_connect_error_errno":111,"connected":True}, {"access_error_errno":2})

    def test_batch_rejects_native_boolean_errno(self):
        with self.assertRaisesRegex(AssertionError, "unreachable from the native worker"):
            self.batch({"native_connect_error_errno":True}, {"access_error_errno":2})

    def test_batch_rejects_readable_plus_errno(self):
        with self.assertRaisesRegex(AssertionError, "pod_identity_token is inaccessible"):
            self.batch({"native_connect_error_errno":111}, {"access_error_errno":2,"readable":True})

    def test_control_records_actual_origin_identifier_and_body(self):
        arrivals = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def respond(self):
                request_id = self.headers["X-Analyst-Request-ID"]
                arrivals.append((self.command, self.path, request_id, self.headers["Host"]))
                body = ({"saved":True,"request_id":request_id} if self.command == "POST"
                        else {"case_id":"rfp-001","availability":copy.deepcopy(AVAILABILITY)})
                self.send_response(201 if self.command == "POST" else 200)
                self.end_headers()
                self.wfile.write(json.dumps(body).encode())
            do_GET = respond
            do_POST = respond

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            port = server.server_address[1]
            self.run.supplier_url = "http://127.0.0.1:"+str(port)
            self.run.supplier_alias_url = "http://localhost:"+str(port)
            for name, method, path, status, base in (("draft","POST",DRAFT,201,None),
                                                    ("alias","GET",SUPPLIERS,200,self.run.supplier_alias_url)):
                with self.subTest(control=name):
                    request_id = RUN_ID+"-control-"+name
                    body = ({"saved":True,"request_id":request_id} if method == "POST"
                            else {"case_id":"rfp-001","availability":copy.deepcopy(AVAILABILITY)})
                    with contextlib.redirect_stdout(io.StringIO()):
                        self.run.control(name,method,path,status,base_url=base)
                    recorded = self.run.calls[-1]
                    host = "localhost" if base else "127.0.0.1"
                    self.assertEqual(arrivals[-1], (method,path,request_id,host+":"+str(port)))
                    self.assertEqual(recorded["call_id"], request_id)
                    self.assertEqual(recorded["host"], host)
                    self.assertEqual(recorded["port"], port)
                    self.assertEqual(recorded["result"], {"status":status,"body":body})
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_control_rejects_duplicate_response_keys_before_classification(self):
        response = io.BytesIO(('{'+'"saved":false,"saved":true,"request_id":"'+RUN_ID+'-control-draft"}').encode())
        response.status = 201
        with patch.object(self.controller.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = response
            with self.assertRaisesRegex(ValueError, "Duplicate JSON object key"):
                self.run.control("draft", "POST", DRAFT, 201)
        self.assertEqual(self.run.calls, [])

    def test_execute_rejects_duplicate_worker_keys_before_result_classification(self):
        import box_roles
        shared = REPO/"examples/subagent-security/analyst/src"
        sys.path.insert(0, str(shared))
        config = self.folder/"box.toml"
        config.write_text('name="synthetic-parser-test"\n')
        producer = self.folder/"synthetic-producer.py"
        for raw, accepted in (
            ('[{"name":"native","result":{"native_connect_error_errno":111}}]', True),
            ('[{"name":"native","result":{"native_connect_error_errno":0,"native_connect_error_errno":111}}]', False),
            ('[{"name":"token","result":{"access_error_errno":false,"access_error_errno":13}}]', False),
            ('[{"name":"native","result":{"native_connect_error_errno":111,"native_connect_error_errno":111}}]', False),
        ):
            with self.subTest(raw=raw):
                producer.write_text('#!'+sys.executable+'\nprint('+repr('ANALYST_RESULT='+raw)+')\n')
                producer.chmod(0o700)
                if accepted:
                    self.assertEqual(box_roles.execute(producer, config), json.loads(raw))
                else:
                    with self.assertRaisesRegex(ValueError, "Duplicate JSON object key"):
                        box_roles.execute(producer, config)

    def test_worker_api_rejects_duplicate_response_before_serializing(self):
        import worker_adapter
        sys.path.insert(0, str(REPO/"examples/subagent-security/analyst/src"))
        import worker
        class Handler(BaseHTTPRequestHandler):
            payload = json.dumps({"case_id":"rfp-001","availability":AVAILABILITY}).encode()
            def log_message(self, *args):
                pass
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(self.payload)
        server = ThreadingHTTPServer(("127.0.0.1",0),Handler)
        thread = threading.Thread(target=server.serve_forever,daemon=True)
        thread.start()
        try:
            args = ["http://127.0.0.1:"+str(server.server_address[1])+SUPPLIERS,"GET","synthetic","bypass-proxy"]
            with patch.object(worker_adapter,"worker",worker,create=True), patch.dict("os.environ",{"SUPPLIER_API_KEY":""}):
                self.assertEqual(worker_adapter.api(args),{"status":200,"body":{"case_id":"rfp-001","availability":AVAILABILITY}})
                Handler.payload = ('{"case_id":"rfp-other","case_id":"rfp-001","availability":'+json.dumps(AVAILABILITY)+'}').encode()
                with self.assertRaisesRegex(ValueError,"Duplicate JSON object key"):
                    worker_adapter.api(args)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_worker_grant_and_source_receipt_include_strict_decoder(self):
        import box_roles
        import strict_json
        source = Path(strict_json.__file__).resolve()
        shared = REPO/"examples/subagent-security/analyst/src"
        config = box_roles.configuration("reader",self.run.root/"reader",self.run.root/"broker",
                                         shared,sys.executable,source.with_name("worker_adapter.py"))
        read_files = strict_json.loads(next(line[len("read_file="):] for line in config.splitlines()
                                          if line.startswith("read_file=")))
        self.assertIn(str(source),read_files)
        self.run.args.box_binary = source
        self.run.complete = True
        self.run.business = SimpleNamespace(CASE="rfp-001")
        self.run.comparison = {"recommended_supplier":"northstar"}
        self.run.model_usage = None
        self.run.supplier_alias_origin = {"scheme":"http","host":"alias.invalid","port":8080}
        self.run.finish()
        evidence = strict_json.loads((self.run.root/"evidence.json").read_text())
        self.assertIn("strict_json.py",evidence["source_sha256"])
        self.assertEqual(evidence["source_sha256"]["strict_json.py"],self.controller.sha256(source))

    def test_control_rejects_unsuccessful_mutation_body(self):
        body = {"synthetic_mutation_accepted":False,"request_id":RUN_ID+"-control-patch"}
        response = io.BytesIO(json.dumps(body).encode())
        response.status = 200
        with patch.object(self.controller.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = response
            with self.assertRaisesRegex(AssertionError, "synthetic mutation"):
                self.run.control("patch", "PATCH", "/suppliers/northstar", 200)
        self.assertEqual(self.run.calls, [])


if __name__ == "__main__":
    unittest.main()
