function results = sweep_params(nBars, nFolds)
%SWEEP_PARAMS Walk-forward sweep of entry threshold x confirmation window.
%   Grid: entryZ 1.8:0.1:2.5  x  confirmBars {0,1,2,3}
%   (at 1-min bars, confirmBars ~ 0/60/120/180 s; true 30 s granularity is
%   not possible bar-based - see README).
%   History is split into nFolds sequential windows; each grid point is
%   evaluated independently per window (fresh engine, shared features), so
%   the score reflects out-of-sample-style stability, not one lucky run.
%   Validates that the journaled defaults (2.0, 1 bar) sit on the
%   efficient frontier rather than being pure intuition.

arguments
    nBars (1,1) double = 6000
    nFolds (1,1) double = 4
end

root = fileparts(mfilename('fullpath'));
addpath(fullfile(root, 'src'));
cfg = jsondecode(fileread(fullfile(root, 'config.json')));
sig = struct();
if isfield(cfg, 'signal'), sig = cfg.signal; end

hist = loadPairHistory(root, cfg, nBars);
fprintf('Computing model features (shared across the grid)...\n');
F = computeFeatures(hist, cfg);

entryZs = 1.8:0.1:2.5;
confirms = 0:3;
n = height(hist);
foldEdges = round(linspace(F.startIdx, n, nFolds + 1));

totalR = zeros(numel(entryZs), numel(confirms));
nTrades = zeros(numel(entryZs), numel(confirms));
hitRate = nan(numel(entryZs), numel(confirms));

for i = 1:numel(entryZs)
    for j = 1:numel(confirms)
        s = sig;
        s.entryZ = entryZs(i);
        s.confirmBars = confirms(j);
        rAll = [];
        for f = 1:nFolds
            eng = SignalEngine(s);
            for k = foldEdges(f):foldEdges(f+1)
                ev = eng.step(struct('t', F.t(k), 'nq', F.nq(k), ...
                    'es', F.es(k), 'z', F.z(k), 'resSd', F.resSd(k), ...
                    'beta', F.beta(k), ...
                    'normNQ', F.normNQ(k), 'normES', F.normES(k), ...
                    'esSlope', F.esSlope(k), 'pVolHMM', F.pVolHMM(k), ...
                    'pVolEwma', F.pVolEwma(k), ...
                    'spansGap', F.spansGap(k))); %#ok<NASGU>
            end
            tr = eng.tradeTable();
            if ~isempty(tr)
                rAll = [rAll; tr.rMultiple]; %#ok<AGROW>
            end
        end
        totalR(i,j) = sum(rAll);
        nTrades(i,j) = numel(rAll);
        if ~isempty(rAll)
            hitRate(i,j) = mean(rAll > 0);
        end
    end
    fprintf('  entryZ %.1f done\n', entryZs(i));
end

% --- report --------------------------------------------------------------
fprintf('\n--- Total R by (entryZ x confirmBars) ---\n');
T = array2table(totalR, 'VariableNames', ...
    compose('confirm%d', confirms), 'RowNames', compose('z%.1f', entryZs));
disp(T);
fprintf('--- Trades ---\n');
disp(array2table(nTrades, 'VariableNames', compose('confirm%d', confirms), ...
    'RowNames', compose('z%.1f', entryZs)));

[iBest, jBest] = find(totalR == max(totalR(:)), 1);
iDef = find(abs(entryZs - 2.0) < 1e-9);
jDef = find(confirms == 1);
fprintf('Best cell: entryZ=%.1f, confirm=%d (R=%+.2f, %d trades)\n', ...
    entryZs(iBest), confirms(jBest), totalR(iBest,jBest), nTrades(iBest,jBest));
fprintf('Journal default (2.0, 1): R=%+.2f, %d trades, hit %.0f%%\n', ...
    totalR(iDef,jDef), nTrades(iDef,jDef), 100*hitRate(iDef,jDef));

% --- heatmap -------------------------------------------------------------
fig = figure('Name', 'Parameter sweep: entryZ x confirmBars', ...
    'NumberTitle', 'off', 'Position', [120 120 760 520]);
h = heatmap(fig, compose('%d bars', confirms), compose('%.1f', entryZs), ...
    round(totalR, 2));
h.Title = 'Total R (walk-forward folds)';
h.XLabel = 'Confirmation window (bars; 1 bar @ 1-min \approx 60 s)';
h.YLabel = 'Entry gate |z|';

results = struct('entryZs', entryZs, 'confirms', confirms, ...
    'totalR', totalR, 'nTrades', nTrades, 'hitRate', hitRate);
end
