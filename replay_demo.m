function replay_demo(nBars, warmN)
%REPLAY_DEMO Offline validation of the NQ-ES pair model.
%   Fetches historical 3-minute bars from TradingView (cached locally),
%   replays them bar-by-bar through the Kalman filter and regime detector,
%   and plots the same outputs the live dashboard shows.
%
%   replay_demo          - replay 5000 bars, 500-bar warm-up
%   replay_demo(N, W)    - custom history depth / warm-up length

arguments
    nBars (1,1) double = 5000
    warmN (1,1) double = 500
end

root = fileparts(mfilename('fullpath'));
addpath(fullfile(root, 'src'));
cfg = loadConfig(root);

% --- history (cached so replay works offline) -------------------------
cacheFile = fullfile(root, 'data', 'history_cache.mat');
maxAgeHours = 12;
useCache = isfile(cacheFile);
if useCache
    info = dir(cacheFile);
    useCache = (now - info.datenum) * 24 < maxAgeHours; %#ok<TNOW1>
end
if useCache
    load(cacheFile, 'hist');
    fprintf('Loaded %d cached bars (%s)\n', height(hist), cacheFile);
else
    feed = TvFeed(cfg);
    hist = feed.getHistory(nBars);
    if ~isfolder(fullfile(root, 'data')), mkdir(fullfile(root, 'data')); end
    save(cacheFile, 'hist');
    fprintf('Fetched and cached %d bars\n', height(hist));
end

% --- warm start --------------------------------------------------------
kf = KalmanHedge();
if isfield(cfg, 'kalmanDelta'), kf.Delta = cfg.kalmanDelta; end
if isfield(cfg, 'zWindow'), kf.ZWindow = cfg.zWindow; end
kf.warmStart(hist.NQ(1:warmN), hist.ES(1:warmN));
fprintf('Warm start (OLS on %d bars): alpha=%.1f, beta=%.4f\n', ...
    warmN, kf.Alpha, kf.Beta);

% --- replay the Kalman filter ------------------------------------------
n = height(hist);
pred = nan(n,1); resid = nan(n,1); z = nan(n,1);
beta = nan(n,1); alpha = nan(n,1); pVol = nan(n,1);
for k = warmN+1:n
    out = kf.update(hist.NQ(k), hist.ES(k));
    pred(k) = out.predictedNQ; resid(k) = out.residual; z(k) = out.zScore;
    beta(k) = out.beta; alpha(k) = out.alpha;
end

% --- regime detection on the Kalman innovations ------------------------
% fit on the same series the detector sees live, then one smoothing pass
% over the full replay for display
regime = RegimeDetector();
fprintf('Fitting Markov-switching regime model on Kalman innovations...\n');
idx = find(~isnan(resid));
regime.fit(resid(idx));
fprintf('Regime method: %s', regime.Method);
if regime.Method == "markov"
    fprintf(' (state stds: %.2f / %.2f pts)', regime.StateStd);
end
fprintf('\n');
pVol(idx) = regime.smoothAll(resid(idx));

v = ~isnan(pred);
fprintf('\n--- Replay of %d bars ---\n', nnz(v));
fprintf('Prediction RMSE: %.2f NQ pts (naive prev-close: %.2f)\n', ...
    rmse(pred(v), hist.NQ(v)), rmse(hist.NQ(find(v)-1), hist.NQ(v)));
fprintf('Beta range: [%.3f, %.3f], final %.4f\n', ...
    min(beta(v)), max(beta(v)), kf.Beta);
fprintf('Residual z-score: mean %.2f, std %.2f, %%|z|>2: %.1f%%\n', ...
    mean(z(v)), std(z(v)), 100*mean(abs(z(v)) > 2));
fprintf('Time in volatile regime: %.1f%%\n', 100*mean(pVol(v) > 0.5));

% --- plots -------------------------------------------------------------
t = hist.t;
fig = figure('Name', 'NQ-ES Pair Model Replay', 'NumberTitle', 'off', ...
    'Position', [80 60 1250 850]);
tl = tiledlayout(fig, 4, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

ax1 = nexttile(tl);
plot(ax1, t, hist.NQ, 'Color', [0.3 0.3 0.35], 'DisplayName', 'NQ actual');
hold(ax1, 'on');
plot(ax1, t, pred, 'Color', [0.85 0.33 0.1], 'DisplayName', 'NQ predicted (Kalman)');
title(ax1, 'Actual vs Kalman-predicted NQ');
legend(ax1, 'Location', 'best'); grid(ax1, 'on');

ax2 = nexttile(tl);
shadeRegime(ax2, t, pVol);
hold(ax2, 'on');
plot(ax2, t, z, 'Color', [0 0.45 0.74], 'DisplayName', 'residual z-score');
yline(ax2, [-2 -1 1 2], ':', 'Color', [0.5 0.5 0.5], 'HandleVisibility', 'off');
yline(ax2, 0, '-', 'Color', [0.4 0.4 0.4], 'HandleVisibility', 'off');
title(ax2, 'Residual z-score (shaded = volatile regime)');
legend(ax2, 'Location', 'best'); grid(ax2, 'on');

ax3 = nexttile(tl);
plot(ax3, t, beta, 'Color', [0.47 0.67 0.19]);
title(ax3, 'Hedge ratio \beta (Kalman)'); grid(ax3, 'on');

ax4 = nexttile(tl);
plot(ax4, t, alpha, 'Color', [0.49 0.18 0.56]);
title(ax4, 'Intercept \alpha (Kalman)'); grid(ax4, 'on');

linkaxes([ax1 ax2 ax3 ax4], 'x');
xlim(ax1, [t(warmN+1) t(end)]);
end

function shadeRegime(ax, t, pVol)
% shade spans where the volatile-regime probability exceeds 0.5
inVol = pVol > 0.5;
d = diff([false; inVol; false]);
starts = find(d == 1); stops = find(d == -1) - 1;
for k = 1:numel(starts)
    xr = [t(starts(k)) t(stops(k))];
    patch(ax, [xr(1) xr(2) xr(2) xr(1)], [-6 -6 6 6], [0.93 0.69 0.13], ...
        'FaceAlpha', 0.18, 'EdgeColor', 'none', 'HandleVisibility', 'off');
end
end

function cfg = loadConfig(root)
cfgFile = fullfile(root, 'config.json');
if isfile(cfgFile)
    cfg = jsondecode(fileread(cfgFile));
else
    cfg = struct();
end
end
