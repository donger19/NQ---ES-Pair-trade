function tests = testSizing
%TESTSIZING Unit tests for the rule-4 position sizing formula.
tests = functiontests(localfunctions);
end

function setupOnce(~)
here = fileparts(mfilename('fullpath'));
addpath(fullfile(fileparts(here), 'src'));
end

function testFullSizeContracts(testCase)
% $500 risk, 10-pt stop: 2 NQ ($400 risked), ES leg from beta.
p = SignalEngine.defaults();
s = SignalEngine.positionSize(500, 10, 7, p);
testCase.verifyEqual(s.nNQ, 2);
testCase.verifyFalse(s.useMicros);
testCase.verifyEqual(s.riskUsed, 400);
testCase.verifyEqual(s.nES, round(2 * 7 * 20 / 50));  % beta-scaled hedge
testCase.verifyLessThanOrEqual(s.riskUsed, 500);
end

function testMicroFallback(testCase)
% 30-pt stop: even 1 NQ risks $600 > $500 -> fall back to micros.
p = SignalEngine.defaults();
s = SignalEngine.positionSize(500, 30, 7, p);
testCase.verifyTrue(s.useMicros);
testCase.verifyEqual(s.nMNQ, 8);                      % floor(500 / 60)
testCase.verifyEqual(s.riskUsed, 480);
testCase.verifyLessThanOrEqual(s.riskUsed, 500);
end

function testStopOutNeverExceedsBudget(testCase)
% Sweep stop distances: a 1R stop-out must never lose more than $500.
p = SignalEngine.defaults();
for stopPts = [1 2.5 5 10 17 25 40 80]
    s = SignalEngine.positionSize(500, stopPts, 6.8, p);
    testCase.verifyLessThanOrEqual(s.riskUsed, 500, ...
        sprintf('stopPts = %.1f breached the risk budget', stopPts));
end
end

function testDegenerateStop(testCase)
p = SignalEngine.defaults();
s = SignalEngine.positionSize(500, 0, 7, p);
testCase.verifyEqual(s.riskUsed, 0);
testCase.verifyEqual(s.nNQ, 0);
end
