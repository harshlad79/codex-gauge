import pathlib, sys, unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".testdeps"))
from lupa.lua51 import LuaRuntime

class GraphTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.model = self.lua.execute((ROOT / "artifacts/rainmeter-skin/@Resources/Scripts/GraphModel.lua").read_text(encoding="utf-8"))
    def build(self, values, step=1800, duration=18000, now=None):
        start = 1700000000
        rows = [{"epoch":start+i*step, "session":v, "weekly":v, "sessionReset":start+18000, "weeklyReset":start+604800} for i,v in enumerate(values)]
        return self.model.build(self.lua.table_from([self.lua.table_from(r) for r in rows]), now or rows[-1]["epoch"])
    def test_session_deltas_weekly_all_layers(self):
        s = self.build([0,10,25,31]).session
        self.assertEqual([s.buckets[i].delta for i in range(1,4)], [10,15,6])
        w = self.build([0,10,25,31], step=43200).weekly
        self.assertEqual([w.buckets[3].layers[i].value for i in range(1,4)], [10,15,6])
        self.assertEqual([w.buckets[3].boundaries[i] for i in range(1,3)], [10,25])
    def test_future_is_unknown(self):
        g = self.build([0,10,25])
        self.assertFalse(g.session.buckets[3].observed)
        self.assertIsNone(g.session.buckets[3].delta)
    def test_partial_bucket(self):
        s = self.build([0,10,25],step=900).session
        self.assertEqual(s.buckets[1].delta,25)
        s = self.build([0,10,25],step=600).session
        self.assertTrue(s.buckets[1].partial)
        self.assertEqual(s.buckets[1].delta,25)
    def test_midwindow_start_not_fabricated(self):
        rows = self.lua.table_from([self.lua.table_from(dict(epoch=1700001800,session=30,weekly=40,sessionReset=1700018000,weeklyReset=1700604800))])
        s = self.model.build(rows,1700001800).session
        self.assertIsNone(s.buckets[1].delta)
        self.assertFalse(s.current.valid)
    def test_hole_not_attributed_to_last_bucket(self):
        rows = [dict(epoch=1700000000+t,session=v,weekly=v,sessionReset=1700018000,weeklyReset=1700604800) for t,v in [(0,0),(1800,10),(7200,60)]]
        s = self.model.build(self.lua.table_from([self.lua.table_from(r) for r in rows]),1700007200).session
        self.assertFalse(s.buckets[2].observed)
        self.assertIsNone(s.buckets[4].delta)
    def test_before_after_reset_crossing(self):
        s = self.build([0,20,40]).session
        self.assertAlmostEqual(s.current.crossingEpoch,1700009000,delta=1)
        self.assertLess(s.current.margin,0)
        s = self.build([0,2,4]).session
        self.assertGreater(s.current.margin,0)
    def test_reset_isolation(self):
        rows = [dict(epoch=1700000000,session=95,weekly=10,sessionReset=1700000000,weeklyReset=1700604800),
                dict(epoch=1700003600,session=3,weekly=11,sessionReset=1700020000,weeklyReset=1700604800)]
        s=self.model.build(self.lua.table_from([self.lua.table_from(r) for r in rows]),1700003600).session
        self.assertFalse(s.current.valid)
    def test_correction_not_negative_usage(self):
        s=self.build([0,20,18,23]).session
        self.assertIsNone(s.buckets[2].delta)
        self.assertEqual(s.buckets[3].delta,5)
    def test_flat_no_infinity(self):
        s=self.build([0,0,0]).session
        self.assertFalse(s.current.valid)
        self.assertIsNone(s.current.crossingEpoch)
    def test_utc_parser_and_malformed_lines(self):
        row=self.model.parseLine('{"timestamp":"2026-09-09T08:29:42.0000000Z","session":7,"weekly":29,"sessionReset":1788946500,"weeklyReset":1789446420}')
        self.assertEqual(row.epoch,1788942582)
        self.assertIsNone(self.model.parseLine('broken'))
    def test_parser_preserves_exponents_and_timezone_offsets(self):
        row=self.model.parseLine('{"timestamp":"2026-09-09T17:29:42.0000000+09:00","session":1E-05,"weekly":29,"sessionReset":1788946500,"weeklyReset":1789446420}')
        self.assertEqual(row.epoch,1788942582)
        self.assertAlmostEqual(row.session,0.00001)
    def test_expired_not_future_prediction(self):
        s=self.build([0,10,25],now=1700020000).session
        self.assertTrue(s.expired)
        self.assertFalse(s.current.valid)
    def test_density_does_not_change_trend(self):
        start=1700000000
        rows=[dict(epoch=start+i*60,session=i/3,weekly=10,sessionReset=start+18000,weeklyReset=start+604800) for i in range(61)]
        a=self.model.build(self.lua.table_from([self.lua.table_from(r) for r in rows]),start+3600)
        b=self.model.build(self.lua.table_from([self.lua.table_from(r) for r in rows for _ in range(3)]),start+3600)
        self.assertAlmostEqual(a.session.current.slope,b.session.current.slope)

    def test_observed_zero_after_reset_is_first_bucket_baseline(self):
        start=1700000000
        rows=[dict(epoch=start+t,session=v,weekly=10,sessionReset=start+18000,weeklyReset=start+604800) for t,v in [(60,0),(1800,10)]]
        s=self.model.build(self.lua.table_from([self.lua.table_from(r) for r in rows]),start+1800).session
        self.assertEqual(s.buckets[1].delta,10)

    def test_overall_equal_cycle_weight_and_distinct_crossings(self):
        start=1700000000;rows=[]
        # Three cycles: 10,20,30 percentage points/hour, deliberately unequal counts.
        for cycle,rate,step in [(-2,10,60),(-1,20,1800),(0,30,900)]:
            origin=start+cycle*18000
            for t in range(0,3601,step):
                rows.append(dict(epoch=origin+t,session=rate*t/3600,weekly=10,sessionReset=origin+18000,weeklyReset=start+604800))
        s=self.model.build(self.lua.table_from([self.lua.table_from(r) for r in rows]),start+3600).session
        self.assertTrue(s.overall.valid)
        self.assertEqual(s.overall.cycles,3)
        self.assertAlmostEqual(s.overall.slope,20/3600)
        self.assertAlmostEqual(s.overall.crossingEpoch,start+16200)
        self.assertAlmostEqual(s.current.crossingEpoch,start+12000)

    def test_reset_timestamp_jitter_is_not_a_new_cycle(self):
        start=1700000000
        rows=[dict(epoch=start+t,session=v,weekly=v,sessionReset=start+18000+j,weeklyReset=start+604800+j) for t,v,j in [(60,0,-30),(900,10,0),(1800,20,1),(2700,30,0)]]
        g=self.model.build(self.lua.table_from([self.lua.table_from(r) for r in rows]),start+2700)
        self.assertEqual(g.session.buckets[1].delta,20)
        self.assertEqual(g.session.overall.cycles,1)
        self.assertEqual(g.weekly.overall.cycles,1)
        self.assertTrue(g.session.current.valid)

    def test_idle_zero_windows_do_not_drown_out_usage_history(self):
        start=1700000000;rows=[]
        for i in range(12):
            origin=start-(i+1)*18000
            for t in [0,60]:
                rows.append(dict(epoch=origin+t,session=0,weekly=0,sessionReset=origin+18000,weeklyReset=origin+604800))
        for t,v in [(0,0),(3600,20)]:
            rows.append(dict(epoch=start+t,session=v,weekly=v,sessionReset=start+18000,weeklyReset=start+604800))
        g=self.model.build(self.lua.table_from([self.lua.table_from(r) for r in rows]),start+3600)
        self.assertTrue(g.session.overall.valid)
        self.assertEqual(g.session.overall.cycles,1)
        self.assertAlmostEqual(g.session.overall.crossingEpoch,start+18000)

if __name__ == "__main__": unittest.main()
