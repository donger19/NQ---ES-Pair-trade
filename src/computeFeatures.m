function F = computeFeatures(hist, cfg)
%COMPUTEFEATURES Per-bar model features for SignalEngine backtests.
%   Replays history through KalmanHedge and RegimeDetector and computes
%   the Pine-side series (normalized trends, ES trend slope) so
%   SignalEngine sees the same inputs the chart indicator sees.
%
%   Trend parameters mirror the Pine input defaults and must be kept in
%   sync with pine/nq_es_pair.pine: normLen = 240, trendLen = 100.

normLen = 240;    % Pine: "Normalization lookback (bars)"
trendLen = 100;   % Pine: "Trend regression lookback (bars)"

n = height(hist);
warmN = min(getOr(cfg, 'warmupBars', 1000), floor(n / 3));
zWin = getOr(cfg, 'zWindow', 60);

kf = KalmanHedge();
kf.Delta = getOr(cfg, 'kalmanDelta', 1e-5);
kf.ZWindow = zWin;
kf.warmStart(hist.NQ(1:warmN), hist.ES(1:warmN));

z = nan(n,1); resid = nan(n,1); beta = nan(n,1); resSd = nan(n,1);
for k = warmN+1:n
    out = kf.update(hist.NQ(k), hist.ES(k));
    z(k) = out.zScore;
    resid(k) = out.residual;
    beta(k) = out.beta;
end
% rolling residual std (mirrors KalmanHedge.ResBuffer: last zWin residuals
% including the current bar; approximate for the first zWin bars)
for k = warmN+1:n
    i0 = max(warmN+1, k - zWin + 1);
    resSd(k) = std(resid(i0:k));
end

% normalized trend lines (Pine: 100 * (x / x[normLen] - 1))
normNQ = nan(n,1); normES = nan(n,1);
idx = normLen+1:n;
normNQ(idx) = 100 * (hist.NQ(idx) ./ hist.NQ(idx - normLen) - 1);
normES(idx) = 100 * (hist.ES(idx) ./ hist.ES(idx - normLen) - 1);

% per-bar linear-regression slope of normES over trendLen bars
% (Pine: ta.linreg(x, len, 0) - ta.linreg(x, len, 1))
esSlope = nan(n,1);
L = trendLen;
x = (1:L)';
sx = sum(x); sxx = sum(x.^2);
denom = L * sxx - sx^2;
for k = normLen+L:n
    y = normES(k-L+1:k);
    esSlope(k) = (L * sum(x .* y) - sx * sum(y)) / denom;
end

% regime probability: fit once on the replayed innovations, one smoothing
% pass for the whole series (same approach as replay_demo display)
pVol = nan(n,1);
regime = RegimeDetector();
regime.Window = getOr(cfg, 'regimeWindow', 400);
iv = find(~isnan(resid));
regime.fit(resid(iv));
pVol(iv) = regime.smoothAll(resid(iv));

F = struct('t', hist.t, 'nq', hist.NQ, 'es', hist.ES, ...
    'z', z, 'resid', resid, 'resSd', resSd, 'beta', beta, ...
    'normNQ', normNQ, 'normES', normES, 'esSlope', esSlope, ...
    'pVol', pVol, 'warmN', warmN, ...
    'startIdx', max(warmN+1, normLen+L), ...
    'regimeMethod', regime.Method);
end

function v = getOr(s, name, default)
if isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
else
    v = default;
end
end
