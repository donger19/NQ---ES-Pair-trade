function results = backtest_rules(nBars)
%BACKTEST_RULES Replay history through the v3 rule engine (SignalEngine).
%   Validates the two journaled trades (Jul 20-21, 2026, overnight):
%     Trade 1: entry at z = -1.97 that chopped (+0.72/-1.01)  -> must be FILTERED
%     Trade 2: fade of a +2.4 z spike, entered after the spike -> must be TAKEN
%              only after the confirmation bar(s) with momentum settled
%   Episodes are located by matching z excursions (approximate times).
%
%   backtest_rules          - 6000 bars at the configured resolution
%   backtest_rules(N)       - custom history depth

arguments
    nBars (1,1) double = 6000
end

root = fileparts(mfilename('fullpath'));
addpath(fullfile(root, 'src'));
cfg = jsondecode(fileread(fullfile(root, 'config.json')));
sig = struct();
if isfield(cfg, 'signal'), sig = cfg.signal; end

hist = loadPairHistory(root, cfg, nBars);
fprintf('Computing model features (Kalman + trends + regime)...\n');
F = computeFeatures(hist, cfg);
fprintf('Regime method: %s\n', F.regimeMethod);

% --- run the rule engine over every closed bar -------------------------
n = height(hist);
eng = SignalEngine(sig);
state = zeros(n,1);
signals = strings(n,1);
for k = F.startIdx:n
    ev = eng.step(struct('t', F.t(k), 'nq', F.nq(k), 'es', F.es(k), ...
        'z', F.z(k), 'resSd', F.resSd(k), 'beta', F.beta(k), ...
        'normNQ', F.normNQ(k), 'normES', F.normES(k), ...
        'esSlope', F.esSlope(k), 'pVolHMM', F.pVolHMM(k), ...
        'pVolEwma', F.pVolEwma(k), 'spansGap', F.spansGap(k)));
    state(k) = ev.state;
    signals(k) = ev.signal;
end
trades = eng.tradeTable();

% --- journaled-trade episode checks -------------------------------------
tz = 'America/New_York';
winLo = datetime(2026, 7, 20, 18, 0, 0, 'TimeZone', tz);
winHi = datetime(2026, 7, 21, 9, 30, 0, 'TimeZone', tz);
inWin = F.t >= winLo & F.t <= winHi;
if ~any(inWin)
    warning('backtest_rules:window', ...
        'No bars in the Jul 20-21 overnight window; scanning full history.');
    inWin = true(n,1);
end

% Episode (a) - Trade 1: z touches [-2.05, -1.8] then stalls inside +/-1.5
% with repeated sign flips over the next 10 bars.
epA = NaN;
cand = find(inWin & F.z >= -2.05 & F.z <= -1.8);
for k = cand(:)'
    hi = min(n, k + 10);
    seg = F.z(k+1:hi);
    if numel(seg) >= 5 && max(abs(seg)) < 1.5 && countFlips(seg) >= 2
        epA = k;
        break
    end
end
fprintf('\n--- Journaled trade validation ---\n');
if isnan(epA)
    fprintf('Trade 1 episode (z ~ -1.97 then chop): NOT FOUND in history.\n');
else
    hi = min(n, epA + 10);
    entered = any(signals(epA:hi) == "enter");
    fprintf('Trade 1 episode at %s (z = %.2f): entry %s -> %s\n', ...
        string(F.t(epA)), F.z(epA), ...
        ternary(entered, "TAKEN", "FILTERED"), ...
        ternary(~entered, "PASS (gate/chop filtered it)", "FAIL (should be filtered)"));
end

% Episode (b) - Trade 2: z spikes >= +2.3 and later reverts. Scan every
% such spike (the first candidate is often a session-reopen artifact the
% confirmation rule correctly skips) and pass if at least one was faded
% short strictly after its breach bar.
epB = NaN; entryK = NaN;
cand = find(inWin & F.z >= 2.3 & [true; F.z(1:end-1) < 2.3]);
for k = cand(:)'
    hi = min(n, k + 60);
    if ~any(F.z(k:hi) < -0.5), continue; end   % journal: spike reverted to -0.90
    if isnan(epB), epB = k; end                % first matching spike, for reporting
    kk = find(signals(k+1:min(n, k+30)) == "enter", 1);
    if ~isempty(kk)
        epB = k;
        entryK = k + kk;
        break
    end
end
if isnan(epB)
    fprintf('Trade 2 episode (z spike >= +2.3 then reversion): NOT FOUND in history.\n');
elseif isnan(entryK)
    fprintf('Trade 2 episodes found (%d spikes) but none entered -> FAIL (a persistent spike fade should be taken)\n', ...
        numel(cand));
else
    fprintf('Trade 2 episode at %s (z = %.2f): entered %s (+%d bars after the spike bar) -> PASS (confirmation delay honored)\n', ...
        string(F.t(epB)), F.z(epB), string(F.t(entryK)), entryK - epB);
end

% --- trade log -----------------------------------------------------------
fprintf('\n--- Closed trades (%d) ---\n', height(trades));
if ~isempty(trades)
    disp(trades(:, {'entryTime', 'exitTime', 'dir', 'entryType', 'entryZ', ...
        'exitZ', 'rMultiple', 'exitReason', 'riskUSD', 'pnlUSD', 'sizeText'}));
    fprintf('Total R: %+.2f | hit rate: %.0f%% | avg R: %+.2f\n', ...
        sum(trades.rMultiple), 100 * mean(trades.rMultiple > 0), ...
        mean(trades.rMultiple));
    for et = ["fade", "convergence"]
        m = trades.entryType == et;
        if any(m)
            fprintf('  %-12s %2d trades | R %+.2f | hit %.0f%%\n', et, ...
                nnz(m), sum(trades.rMultiple(m)), 100 * mean(trades.rMultiple(m) > 0));
        end
    end
else
    fprintf('(none)\n');
end

% --- plot: z, state path, entries/exits ----------------------------------
fig = figure('Name', 'v3 Rule Backtest', 'NumberTitle', 'off', ...
    'Position', [90 80 1250 700]);
tl = tiledlayout(fig, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

ax1 = nexttile(tl);
plot(ax1, F.t, F.z, 'Color', [0 0.45 0.74]);
hold(ax1, 'on');
yline(ax1, [-2 2], ':', 'Color', [0.85 0.2 0.2], 'HandleVisibility', 'off');
yline(ax1, [-1.5 -1 1 1.5], ':', 'Color', [0.6 0.6 0.6], 'HandleVisibility', 'off');
ke = find(signals == "enter");
kx = find(signals == "exit" | signals == "stop");
plot(ax1, F.t(ke), F.z(ke), '^', 'Color', [0.28 0.7 0.32], ...
    'MarkerFaceColor', [0.28 0.7 0.32], 'DisplayName', 'entry');
plot(ax1, F.t(kx), F.z(kx), 'x', 'Color', [0.85 0.2 0.2], ...
    'LineWidth', 1.5, 'DisplayName', 'exit/stop');
title(ax1, 'Residual z-score with v3 entries/exits');
legend(ax1, 'Location', 'best'); grid(ax1, 'on');

ax2 = nexttile(tl);
stairs(ax2, F.t, state, 'Color', [0.49 0.18 0.56]);
yticks(ax2, 0:5);
yticklabels(ax2, {'FLAT', 'ARMED', 'PENDING', 'IN POS', 'TP', 'REV?'});
ylim(ax2, [-0.5 5.5]);
title(ax2, 'Signal state machine path');
grid(ax2, 'on');
linkaxes([ax1 ax2], 'x');

results = struct('trades', {trades}, 'state', state, 'signals', signals, ...
    'features', F, 'episodeA', epA, 'episodeB', epB);
end

function c = countFlips(seg)
s = sign(seg(seg ~= 0));
c = sum(diff(s) ~= 0);
end

function out = ternary(cond, a, b)
if cond, out = a; else, out = b; end
end
