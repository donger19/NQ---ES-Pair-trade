function F = computeFeatures(hist, cfg)
%COMPUTEFEATURES Per-bar model features for SignalEngine backtests.
%   Replays history through KalmanHedge and RegimeDetector and computes
%   the Pine-side series (normalized trends, ES trend slope) so
%   SignalEngine sees the same inputs the chart indicator sees.
%
%   Every series here is CAUSAL: feature(k) depends only on bars 1..k.
%   The regime model's parameters are estimated once on a leading
%   in-sample slice and then applied forward by a filter, never by a
%   full-sample smoother. Do not reintroduce RegimeDetector.smoothAll
%   here - it looks ahead and silently inflates backtest results.
%
%   Trend parameters mirror the Pine input defaults and must be kept in
%   sync with pine/nq_es_pair.pine.

normLen = getOr(cfg, 'normLen', 240);    % Pine: "Normalization lookback"
trendLen = getOr(cfg, 'trendLen', 100);  % Pine: "Trend regression lookback"

n = height(hist);
warmN = min(getOr(cfg, 'warmupBars', 1000), floor(n / 3));
zWin = getOr(cfg, 'zWindow', 60);
barSec = 60 * str2double(string(getOr(cfg, 'resolution', "1")));

kf = KalmanHedge();
kf.Delta = getOr(cfg, 'kalmanDelta', 1e-8);
kf.ZWindow = zWin;
kf.EsRef = getOr(cfg, 'esRefPrice', 7550);
% Naive seed and a run from bar 1, exactly as the Pine indicator does. The
% reparameterized filter is identified, so this converges to the same place
% an OLS warm start would - and it is reproducible on the chart, which an
% OLS warm start over a scroll-dependent history window is not.
kf.seed(hist.NQ(1));

z = nan(n,1); resid = nan(n,1); beta = nan(n,1);
betaLog = nan(n,1); resSd = nan(n,1);
for k = 1:n
    out = kf.update(hist.NQ(k), hist.ES(k));
    z(k) = out.zScore;
    resid(k) = out.residual;
    beta(k) = out.beta;           % price-space hedge ratio dNQ/dES
    betaLog(k) = out.betaLog;
    % single source of truth: the same window std that produced z(k)
    resSd(k) = out.resSd;
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

% ---- regime: parameters fit in-sample, then filtered forward ----------
% Two models are carried because SignalEngine gates on their AGREEMENT:
%   pVolHMM  - 2-state Markov-switching, run as a causal forward filter
%   pVolEwma - EWMA vol-ratio, identical to the Pine fallback
regime = RegimeDetector();
regime.Window = getOr(cfg, 'regimeWindow', 400);
regime.VolThreshold = getOr(cfg, 'volThreshold', 1.5);

% Fit on a leading slice that starts after the filter burn-in, so the
% regime parameters are not contaminated by convergence transients.
iv = find(~isnan(resid));
iv = iv(iv > warmN);
fitBars = min(getOr(cfg, 'regimeFitBars', 5000), numel(iv));
regime.fit(resid(iv(1:fitBars)));      % in-sample slice only
prm = regime.paramsHMM();

pVolHMM = nan(n,1);
pVolEwma = nan(n,1);
pVolHMM(iv) = regime.filterHMM(resid(iv), prm);
pVolEwma(iv) = regime.filterEwma(resid(iv));

% ---- session gaps ------------------------------------------------------
% CME halts and weekends leave holes in the bar series. Lookback-based
% rules (velBars, chopWindow, convBars, intertwineBars) would otherwise
% treat bars either side of a hole as adjacent minutes.
rt = hist.Properties.RowTimes;
dt = [Inf; seconds(diff(rt))];
newSession = dt > 1.5 * barSec;
% bars still inside the longest lookback window after a gap
maxLook = max([getOr(cfg,'velBars',3), getOr(cfg,'chopWindow',10), ...
    getOr(cfg,'convBars',5), getOr(cfg,'intertwineBars',4)]);
barsSinceGap = zeros(n,1);
c = Inf;
for k = 1:n
    if newSession(k), c = 0; else, c = c + 1; end
    barsSinceGap(k) = c;
end
spansGap = barsSinceGap < maxLook;

F = struct('t', rt, 'nq', hist.NQ, 'es', hist.ES, ...
    'z', z, 'resid', resid, 'resSd', resSd, 'beta', beta, ...
    'betaLog', betaLog, 'esRef', kf.EsRef, ...
    'normNQ', normNQ, 'normES', normES, 'esSlope', esSlope, ...
    'pVolHMM', pVolHMM, 'pVolEwma', pVolEwma, ...
    'newSession', newSession, 'barsSinceGap', barsSinceGap, ...
    'spansGap', spansGap, ...
    'warmN', warmN, 'normLen', normLen, 'trendLen', trendLen, ...
    ... % Burn in past the filter's convergence transient AND a full
    ... % zWindow, so resSd is a steady-state estimate before anything is
    ... % sized off it. KalmanHedge returns NaN resSd until the window fills.
    'startIdx', max(warmN + zWin + 1, normLen + L), ...
    'regimeParams', prm, ...
    'regimeFitBars', fitBars, ...
    'regimeMethod', regime.Method);
end

function v = getOr(s, name, default)
if isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
else
    v = default;
end
end
