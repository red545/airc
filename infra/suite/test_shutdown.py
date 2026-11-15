import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from shutdown import ShutdownObservation, apply_policy, gate_inputs
from run import case_outcome, summarize


def event(seconds=9.5, load=20, cores=10, kind='slow-quit'):
    return dict(kind=kind, seconds=seconds, load_1m=load, cores=cores, message='observed slow quit')


def case(name, events, state='PASS'):
    return dict(id='chromium/'+name, engine='chromium', state=state, critical=False,
                worker_exit=0, shutdown_events=events)


class ShutdownTest(unittest.TestCase):
    def test_live_log_observations_capture_load_once_and_ignore_previous_case(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); snapshots=root/'snapshots'; snapshots.mkdir()
            log=snapshots/'log.txt'
            old='SLOW-QUIT old: still quitting 9.5 s after the check finished\n'
            log.write_text(old)
            monitor=ShutdownObservation(snapshots,root/'evidence')
            with patch('shutdown.os.getloadavg',return_value=(12.5,10,8)), patch('shutdown.os.cpu_count',return_value=10):
                monitor.sample()
                self.assertEqual(monitor.events,[])
                log.write_text('SLOW-QUIT smoke: still quitting 3.0 s after the check finished\n')
                monitor.sample(); monitor.sample()
                self.assertEqual(len(monitor.events),1)
                self.assertEqual(monitor.events[0]['load_1m'],12.5)
                log.write_text(log.read_text()+'SLOW-QUIT smoke: still quitting 9.5 s after the check finished\n')
                monitor.stderr.write_text('Teardown watchdog expired\n')
                monitor.sample()
            self.assertEqual(len(monitor.events),3)
            self.assertEqual(json.loads((root/'evidence/shutdown.json').read_text())['events'],monitor.events)

    def test_three_second_warning_never_suppresses_a_gate_red(self):
        result=dict(cases=[case('a',[event(seconds=3,load=0)]),case('b',[event(seconds=3)],'FAIL')])
        apply_policy(result)
        self.assertEqual([c['state'] for c in result['cases']],['PASS','FAIL'])
        self.assertEqual(result['severe_quit_occurrences'],0)
        self.assertTrue(all(e['severity']=='WARNING' for e in result['shutdown_warnings']))

    def test_quiet_or_unknown_load_is_critical_even_once(self):
        for load in [0,9.99,None]:
            result=dict(cases=[case('a',[event(load=load)])])
            apply_policy(result)
            self.assertEqual(result['cases'][0]['state'],'FAIL')
            self.assertTrue(result['cases'][0]['critical'])
        result=dict(cases=[case('a',[event(load=10)])])
        apply_policy(result)
        self.assertEqual(result['cases'][0]['state'],'PASS')

    def test_third_quit_escalates_retained_cases_after_resume_without_double_counting(self):
        events=[event(seconds=3),event(),event(kind='teardown-watchdog',seconds=None)]
        result=dict(cases=[case('a',events),case('b',[event()])])
        apply_policy(result)
        self.assertEqual(result['severe_quit_occurrences'],2)
        self.assertEqual([c['state'] for c in result['cases']],['PASS','PASS'])
        resumed=json.loads(json.dumps(result))
        resumed['cases'].append(case('c',[event()]))
        resumed.update(state='running',expected=3,dry_run=False,steps={})
        summarize(resumed,{})
        self.assertEqual(resumed['severe_quit_occurrences'],3)
        self.assertEqual(resumed['counts']['chromium']['FAIL'],3)
        self.assertEqual(len(resumed['critical']),3)
        apply_policy(resumed)
        self.assertTrue(all(c['gate_state']=='PASS' and c['state']=='FAIL' for c in resumed['cases']))

    def test_only_proved_chromium_teardown_exit_can_be_warning(self):
        receipt=dict(state='FAIL',launches=[dict(state='FAIL',failures=[dict(message='launcher exit 2')])])
        original=json.loads(json.dumps(receipt))
        events=[event(kind='teardown-watchdog',seconds=None)]
        normalized,rc=gate_inputs(receipt,2,events,'chromium')
        self.assertEqual(case_outcome('PASS assertion\n',normalized,rc),('PASS',False))
        self.assertEqual(receipt,original)
        self.assertEqual(case_outcome('FAIL assertion\n',normalized,rc),('FAIL',False))
        for engine, observations in [('webkit',events),('chromium',[]),('chromium',[event()])]:
            r,c=gate_inputs(receipt,2,observations,engine)
            self.assertEqual(case_outcome('PASS assertion\n',r,c)[0],'FAIL')
        receipt['launches'][0]['failures'].append(dict(message='app crashed'))
        r,c=gate_inputs(receipt,2,events,'chromium')
        self.assertEqual(case_outcome('PASS assertion\n',r,c),('FAIL',True))
        r,c=gate_inputs(original,7,events,'chromium')
        self.assertEqual(case_outcome('PASS assertion\n',r,c)[0],'FAIL')

    def test_warning_cannot_clear_environment_or_missing_launch(self):
        for receipt in [dict(state='ENV',errors=['probe unavailable'],launches=[]),
                        dict(state='ENV',launches=[dict(state='ENV',failures=[])])]:
            r,c=gate_inputs(receipt,0,[event(kind='teardown-watchdog')],'chromium')
            self.assertEqual(case_outcome('PASS assertion\n',r,c)[0],'ENV')

if __name__=='__main__': unittest.main()
