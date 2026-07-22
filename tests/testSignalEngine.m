function tests = testSignalEngine
%TESTSIGNALENGINE Unit tests for the v3 rule state machine (SignalEngine).
tests = functiontests(localfunctions);
end

function setupOnce(~)
here = fileparts(mfilename('fullpath'));
addpath(fullfile(fileparts(here), 'src'));
end

% ── Rule 1: entry gate ──────────────────────────────────────────────────
function testEntryGateBlocksBelowThreshold(testCase)
% z = -1.97 (the journaled Trade 1 entry) must produce NO entry, ever.
eng = SignalEngine(struct());
zs = [0 0 0 0 -1.97 -1.97 -1.97 -1.97 -1.97];
sigs = drive(eng, zs);
testCase.verifyEqual(eng.State, 0);
testCase.verifyFalse(any(sigs == "pending"), 'z below gate must not arm');
testCase.verifyFalse(any(sigs == "enter"), 'z below gate must not enter');
testCase.verifyEmpty(eng.Trades);
end

function testEntryAfterConfirmation(testCase)
% z beyond the gate enters only AFTER confirmBars, never on the breach bar.
eng = SignalEngine(struct());
sigs = drive(eng, [0 -0.7 -1.4 -1.9 -2.05 -2.1]);
testCase.verifyEqual(sigs(5), "pending", 'breach bar must only arm');
testCase.verifyEqual(sigs(6), "enter", 'entry on the confirmation bar');
testCase.verifyEqual(eng.State, 3);
testCase.verifyEqual(eng.Dir, 1, 'negative z fade = long NQ / short ES');
end

% ── Rule 2: spike confirmation & momentum veto ─────────────────────────
function testSpikeVetoDelaysEntry(testCase)
% A one-bar jump to -2.5 arms, but entry waits until z velocity decays.
eng = SignalEngine(struct());
sigs = drive(eng, [0 0 0 0 -2.5 -2.5 -2.5 -2.5]);
testCase.verifyEqual(sigs(5), "pending");
testCase.verifyEqual(sigs(6), "", 'zVel = -2.5, veto holds');
testCase.verifyEqual(sigs(7), "", 'zVel = -2.5, veto holds');
testCase.verifyEqual(sigs(8), "enter", 'velocity decayed -> enter');
end

function testExtremeSpikeNeverFaded(testCase)
% z = -4.25 during a violent move is the move registering - no fade.
eng = SignalEngine(struct());
sigs = drive(eng, [0 0 0 0 -4.25 -4.25 -4.25 -4.25 -4.25 -4.25]);
testCase.verifyEqual(eng.State, 0);
testCase.verifyFalse(any(sigs == "pending" | sigs == "enter"), ...
    'beyond the hard-stop level nothing may arm');
testCase.verifyEmpty(eng.Trades);
end

% ── Rule 3: chop filter ─────────────────────────────────────────────────
function testChopFixtureNoEntry(testCase)
% The journaled Trade 1 stall: z bouncing +0.72 / -1.01 -> weak, no entry.
eng = SignalEngine(struct());
zs = repmat([0.72 -1.01], 1, 6);
sawChop = false;
for z = zs
    ev = eng.step(mkbar(z));
    sawChop = sawChop || ev.isChop;
end
testCase.verifyTrue(sawChop, 'the fixture must register as chop');
testCase.verifyEqual(eng.State, 0);
testCase.verifyEmpty(eng.Trades);
end

% ── Rule 4: consolidation exit ──────────────────────────────────────────
function testConsolidationExit(testCase)
% After entry, z pinned inside +/-1.0 for consolBars bars -> exit flat.
eng = SignalEngine(struct());
drive(eng, [0 -0.7 -1.4 -1.9 -2.05 -2.1]);       % entry (long)
testCase.assertEqual(eng.State, 3);
sigs = drive(eng, [-0.9 -0.9 -0.9 -0.9]);
testCase.verifyEqual(sigs(end), "exit");
testCase.verifyEqual(eng.State, 0);
testCase.verifyEqual(height(eng.tradeTable()), 1);
testCase.verifyEqual(eng.Trades(1).exitReason, "consolidation");
end

% ── Rule 5: in-position reversal on adverse trend cross ────────────────
function testReversalEligibleOnAdverseCross(testCase)
eng = SignalEngine(struct());
drive(eng, [0 -0.7 -1.4 -1.9 -2.05 -2.1]);       % entry long (dir = +1)
testCase.assertEqual(eng.State, 3);
ev = eng.step(mkbar(-1.5, 'normNQ', -1));         % NQ crosses under ES
testCase.verifyEqual(ev.signal, "reversal_eligible");
testCase.verifyEqual(eng.State, 5);
ev = eng.step(mkbar(-1.5, 'normNQ', -1));
testCase.verifyEqual(ev.signal, "exit");
testCase.verifyEqual(eng.Trades(end).exitReason, "reversal");
testCase.verifyEqual(eng.State, 0);
end

% ── Rule 8: manual gap policy ───────────────────────────────────────────
function testGapPolicyBlocksCounterGap(testCase)
% Gap points up; a short-NQ fade is counter-gap -> blocked under "block".
eng = SignalEngine(struct('gapDir', 'up', 'gapPolicy', 'block'));
sigs = drive(eng, [0 0.7 1.4 1.9 2.05 2.1]);
testCase.verifyEqual(sigs(end), "gap_blocked");
testCase.verifyEqual(eng.State, 0);
testCase.verifyEmpty(eng.Trades);
end

function testGapPolicyHalvesCounterGap(testCase)
eng = SignalEngine(struct('gapDir', 'up', 'gapPolicy', 'half'));
sigs = drive(eng, [0 0.7 1.4 1.9 2.05 2.1]);
testCase.verifyEqual(sigs(end), "enter");
drive(eng, 4.5);                                  % hard stop closes it
tr = eng.tradeTable();
testCase.assertEqual(height(tr), 1);
testCase.verifyLessThanOrEqual(tr.riskUSD, 250 + 1e-9, ...
    'counter-gap half policy must risk at most half the budget');
end

% ── helpers ─────────────────────────────────────────────────────────────
function bar = mkbar(z, varargin)
bar = struct('t', NaT, 'nq', 20000, 'es', 5000, 'z', z, 'resSd', 10, ...
    'beta', 7, 'normNQ', 1, 'normES', 0, 'esSlope', 0, 'pVol', 0);
for i = 1:2:numel(varargin)
    bar.(varargin{i}) = varargin{i+1};
end
end

function sigs = drive(eng, zs)
sigs = strings(numel(zs), 1);
for k = 1:numel(zs)
    ev = eng.step(mkbar(zs(k)));
    sigs(k) = ev.signal;
end
end
