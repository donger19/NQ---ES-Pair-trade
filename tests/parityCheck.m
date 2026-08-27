function rep = parityCheck(csvPath, opts)
%PARITYCHECK Diff the Pine indicator against SignalEngine, bar for bar.
%   Pine cannot run headlessly, so the indicator exports its internal state
%   as numeric columns (enable "Emit parity export columns", then
%   File > Export chart data) and this harness replays the same bars
%   through computeFeatures + SignalEngine and compares.
%
%   rep = parityCheck('pine_export.csv')
%   rep = parityCheck(csv, BurnIn=1200, Cache="data/history_cache_1m.mat")
%
%   GATE 0 comes first: if the exported px_nq/px_es do not match the cached
%   bars, the chart and the backtest are not looking at the same data
%   (wrong symbol, wrong session, contract rollover) and every other row
%   below is meaningless. That check fails loudly rather than reporting
%   thousands of downstream mismatches.
%
%   Chart requirements: CME_MINI:NQ1! / CME_MINI:ES1!, 1-minute, extended
%   hours ON, scrolled left far enough to load the range you want compared.

arguments
    csvPath (1,1) string
    opts.BurnIn (1,1) double = 1200
    opts.Cache (1,1) string = ""
    opts.TolZ (1,1) double = 5e-3
    opts.TolRel (1,1) double = 1e-6
    opts.Verbose (1,1) logical = true
end

root = fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(root, 'src'));
cfg = jsondecode(fileread(fullfile(root, 'config.json')));

px = readtable(csvPath, 'VariableNamingRule', 'preserve');
tcol = find(contains(lower(px.Properties.VariableNames), 'time'), 1);
assert(~isempty(tcol), 'parityCheck:noTime', 'No time column in %s', csvPath);
pt = px{:, tcol};
if ~isdatetime(pt)
    pt = datetime(string(pt), 'InputFormat', 'yyyy-MM-dd''T''HH:mm:ssXXX', ...
        'TimeZone', 'America/New_York');
end
pt.TimeZone = 'America/New_York';

if opts.Cache == ""
    hist = loadPairHistory(string(root), cfg, 5000, Offline=true);
else
    S = load(opts.Cache, 'hist'); hist = S.hist;
end

% ---- join on timestamp -------------------------------------------------
[tf, loc] = ismember(pt, hist.Properties.RowTimes);
if ~any(tf)
    error('parityCheck:noOverlap', ...
        ['No timestamps in common between the export and the cache.\n' ...
         'Export spans %s to %s; cache spans %s to %s.'], ...
        string(min(pt)), string(max(pt)), ...
        string(min(hist.Properties.RowTimes)), string(max(hist.Properties.RowTimes)));
end
px = px(tf, :); pt = pt(tf); loc = loc(tf);
if opts.Verbose
    fprintf('Joined %d bars, %s -> %s\n', numel(pt), string(min(pt)), string(max(pt)));
end

% ---- GATE 0: same bars? ------------------------------------------------
rep = struct();
g0 = struct('nqMaxAbs', NaN, 'esMaxAbs', NaN, 'pass', false);
if all(ismember({'px_nq','px_es'}, px.Properties.VariableNames))
    g0.nqMaxAbs = max(abs(px.px_nq - hist.NQ(loc)));
    g0.esMaxAbs = max(abs(px.px_es - hist.ES(loc)));
    g0.pass = g0.nqMaxAbs < 1e-9 && g0.esMaxAbs < 1e-9;
end
rep.gate0 = g0;
if ~g0.pass
    fprintf(2, ['\nGATE 0 FAILED: the exported bars are not the cached bars.\n' ...
        '  max|px_nq - cache.NQ| = %.6g\n  max|px_es - cache.ES| = %.6g\n' ...
        'Check the chart symbols, the 1-minute timeframe, extended hours,\n' ...
        'and the continuous-contract rollover. Nothing below is meaningful\n' ...
        'until this passes.\n\n'], g0.nqMaxAbs, g0.esMaxAbs);
    rep.pass = false;
    return
end
if opts.Verbose, fprintf('Gate 0 OK: exported bars match the cache exactly.\n'); end

% ---- replay the same range through the MATLAB side ---------------------
F = computeFeatures(hist, cfg);
eng = SignalEngine(cfg.signal);
n = height(hist);
mState = nan(n,1); mDir = nan(n,1); mSig = zeros(n,1); mGates = nan(n,1);
mNQ = nan(n,1); mES = nan(n,1);
codes = parityCodes();
for k = F.startIdx:n
    o = eng.step(struct('t', F.t(k), 'nq', F.nq(k), 'es', F.es(k), 'z', F.z(k), ...
        'resSd', F.resSd(k), 'beta', F.beta(k), 'normNQ', F.normNQ(k), ...
        'normES', F.normES(k), 'esSlope', F.esSlope(k), ...
        'pVolHMM', F.pVolHMM(k), 'pVolEwma', F.pVolEwma(k), ...
        'spansGap', F.spansGap(k)));
    mState(k) = o.state; mDir(k) = o.dir;
    if isKey(codes.signalFromName, char(o.signal))
        mSig(k) = codes.signalFromName(char(o.signal));
    end
    if isfield(o, 'gates'), mGates(k) = o.gates; end
    if isfield(o, 'nNQ'), mNQ(k) = o.nNQ; mES(k) = o.nES; end
end

% ---- compare -----------------------------------------------------------
keep = loc >= (F.startIdx + opts.BurnIn);
if ~any(keep)
    error('parityCheck:allBurnedIn', ...
        'Every joined bar is inside the %d-bar burn-in; export a longer range.', opts.BurnIn);
end
i = loc(keep);
rows = cell(0, 7);
ptKeep = pt(keep);
    function addRow(name, pineVal, matVal, tol, exact)
        if isempty(pineVal)
            rows(end+1,:) = {string(name), 0, 0, NaN, tol, "-", "SKIP (no column)"}; %#ok<AGROW>
            return
        end
        d = abs(pineVal - matVal);
        ok = ~isnan(d);
        if ~any(ok)
            % All-NaN would otherwise report zero mismatches and look like a
            % pass. It is not a pass - the column was never compared.
            rows(end+1,:) = {string(name), 0, 0, NaN, tol, "-", "SKIP (all NaN)"}; %#ok<AGROW>
            return
        end
        if exact
            isBad = ok & (d ~= 0);
        else
            isBad = ok & (d > tol);
        end
        nMis = sum(isBad);
        firstBad = "-";
        b = find(isBad, 1);
        if ~isempty(b), firstBad = string(ptKeep(b)); end
        verdict = "PASS";
        if nMis > 0, verdict = "FAIL"; end
        rows(end+1,:) = {string(name), sum(ok), nMis, max(d(ok)), tol, firstBad, verdict}; %#ok<AGROW>
    end

    function v = col(name)
        if ismember(name, px.Properties.VariableNames)
            v = px.(name); v = v(keep);
        else
            v = [];
        end
    end

addRow('z',        col('px_z'),        F.z(i),        opts.TolZ,   false);
addRow('betaPx',   col('px_betaPx'),   F.beta(i),     opts.TolRel*10, false);
addRow('betaLog',  col('px_betaLog'),  F.betaLog(i),  opts.TolRel*10, false);
addRow('resSd',    col('px_resSd'),    F.resSd(i),    opts.TolRel*100, false);
addRow('pVolHMM',  col('px_pVolHMM'),  F.pVolHMM(i),  1e-4,        false);
addRow('pVolEwma', col('px_pVolEwma'), F.pVolEwma(i), 1e-4,        false);
addRow('state',    col('px_state'),    mState(i),     0,           true);
addRow('dir',      col('px_dir'),      mDir(i),       0,           true);
addRow('signal',   col('px_signal'),   mSig(i),       0,           true);
addRow('gates',    col('px_gates'),    mGates(i),     0,           true);
addRow('nNQ',      col('px_nNQ'),      mNQ(i),        0,           true);
addRow('nES',      col('px_nES'),      mES(i),        0,           true);

rep.summary = cell2table(rows, 'VariableNames', ...
    {'column','nCompared','nMismatched','maxAbsDiff','tolerance','firstMismatch','verdict'});
% A skipped column is not a pass: parity is only proven over what was
% actually compared, and silence about a missing column hides drift.
rep.pass = all(rep.summary.verdict == "PASS");
rep.skipped = rep.summary.column(startsWith(rep.summary.verdict, "SKIP"));
rep.burnIn = opts.BurnIn;
rep.nJoined = numel(pt);

if opts.Verbose
    fprintf('\n'); disp(rep.summary);
    if rep.pass
        fprintf('PARITY PASS: Pine and SignalEngine agree on every compared column.\n');
    else
        fprintf(2, 'PARITY FAIL: see nMismatched above; firstMismatch localises it.\n');
    end
end
end
