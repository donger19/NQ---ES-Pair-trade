function rep = swingStats(opts)
%SWINGSTATS Swing-leg amplitudes and fixed-barrier EV for outright NQ sizing.
%
%   How big is a typical NQ swing, and does a fixed stop/target pair with
%   1.5 R:R actually clear its break-even hit rate? Two separate questions,
%   answered separately:
%
%     (1) SWING LEGS. Fractal pivots (k bars either side) on 1/5/15/60-min
%         bars, alternating high-low-high, leg amplitude in NQ points. This
%         says what the market offers.
%     (2) FIXED BARRIERS. From each start bar, walk forward and see which
%         touches first: +tp or -sl. This says what you would actually
%         capture, which is a different number, because a swing that
%         eventually runs 120 points can retrace 60 against you first.
%
%   Barrier results are split by higher-timeframe bias (60m and 15m
%   regression slope, both taken from the last CLOSED HTF bar so nothing
%   looks ahead) to test whether HTF agreement lifts the hit rate above
%   break-even.
%
%   rep = swingStats
%   rep = swingStats(Pivot=5, Horizon=240, Sessions=true)
%
%   NOTE ON DATA. The cache stores CLOSES only, so intrabar extremes are
%   not available. Higher-timeframe OHLC is reconstructed from 1-min
%   closes, and the barrier walk tests closes. Both therefore UNDERSTATE
%   touch rates - a real wick can take out a stop this test never sees.
%   Treat every hit rate below as an optimistic bound.

arguments
    opts.Pivot    (1,1) double = 5      % bars either side for a fractal pivot
    opts.Horizon  (1,1) double = 240    % max bars (1-min) to resolve a barrier
    opts.Step     (1,1) double = 5      % sample every Nth bar as a trade start
    opts.RiskUSD  (1,1) double = 1000
    opts.RR       (1,1) double = 1.5
    opts.PtValue  (1,1) double = 20     % NQ $ per point
    opts.Sessions (1,1) logical = true
end

root = fileparts(fileparts(mfilename('fullpath')));
S    = load(fullfile(root, 'data', 'history_cache_1m.mat'));
h1   = S.hist;

t  = h1.Properties.RowTimes;
nq = h1.NQ;
ok = ~isnan(nq);
t  = t(ok);  nq = nq(ok);

fprintf('\n=== NQ swing statistics ===\n');
fprintf('%d 1-min closes, %s -> %s (%s)\n', numel(nq), ...
    string(min(t)), string(max(t)), t.TimeZone);
fprintf('Closes only - no intrabar extremes. Hit rates are optimistic bounds.\n');

%% ── 1. Swing-leg amplitudes per timeframe ──────────────────────────────
tfList = [1 5 15 60];
rows   = strings(0,1);
legTbl = table();
rep.legs = struct();

fprintf('\n--- Swing legs (fractal pivot, k=%d bars either side) ---\n', opts.Pivot);
fprintf('%6s %7s %8s %8s %8s %8s %8s %9s %9s\n', ...
    'TF', 'n legs', 'mean', 'median', 'p25', 'p75', 'p90', '%>=50pt', '%>=75pt');

for tf = tfList
    [bt, ~, hi, lo, cl] = resampleOHLC(t, nq, minutes(tf));
    [pIdx, pPx] = zigzagPivots(hi, lo, opts.Pivot);
    if numel(pIdx) < 3
        continue
    end
    amp = abs(diff(pPx));
    dur = minutes(bt(pIdx(2:end)) - bt(pIdx(1:end-1)));
    up  = diff(pPx) > 0;

    fprintf('%5dm %7d %8.1f %8.1f %8.1f %8.1f %8.1f %8.0f%% %8.0f%%\n', ...
        tf, numel(amp), mean(amp), median(amp), ...
        prctile(amp,25), prctile(amp,75), prctile(amp,90), ...
        100*mean(amp>=50), 100*mean(amp>=75));

    f = sprintf('tf%dm', tf);
    rep.legs.(f) = struct('amp', amp, 'durMin', dur, 'isUp', up, ...
        'pivotTimes', bt(pIdx), 'pivotPx', pPx);
    rows(end+1,1) = string(f); %#ok<AGROW>
    legTbl = [legTbl; table(tf, numel(amp), mean(amp), median(amp), ...
        median(dur), 100*mean(amp>=75), ...
        'VariableNames', {'tfMin','nLegs','meanPts','medPts','medDurMin','pctGE75'})]; %#ok<AGROW>
end
rep.legTable = legTbl;

% duration: how long does a leg take, i.e. how long must you sit in one
fprintf('\n--- Leg duration (minutes) ---\n');
fprintf('%6s %8s %8s %8s\n', 'TF', 'median', 'p75', 'p90');
for f = rows'
    d = rep.legs.(f).durMin;
    fprintf('%6s %8.0f %8.0f %8.0f\n', f, median(d), prctile(d,75), prctile(d,90));
end

% up vs down legs: is there an asymmetry worth knowing about
fprintf('\n--- Up vs down legs (15m) ---\n');
if isfield(rep.legs, 'tf15m')
    a = rep.legs.tf15m.amp;  u = rep.legs.tf15m.isUp;
    fprintf('up   : n=%4d  mean %6.1f  median %6.1f pts\n', sum(u),  mean(a(u)),  median(a(u)));
    fprintf('down : n=%4d  mean %6.1f  median %6.1f pts\n', sum(~u), mean(a(~u)), median(a(~u)));
end

%% ── 2. Session breakdown (15m legs) ────────────────────────────────────
if opts.Sessions && isfield(rep.legs, 'tf15m')
    pt   = rep.legs.tf15m.pivotTimes;
    amp  = rep.legs.tf15m.amp;
    hh   = hour(pt(1:end-1)) + minute(pt(1:end-1))/60;   % leg START hour, ET
    sess = repmat("other", numel(amp), 1);
    sess(hh >= 20 | hh < 0.001)              = "asia_2000_0000";
    sess(hh >= 2  & hh < 5)                  = "london_0200_0500";
    sess(hh >= 9.5 & hh < 11)                = "nyam_0930_1100";
    sess(hh >= 13.5 & hh < 16)               = "nypm_1330_1600";

    fprintf('\n--- 15m leg amplitude by session (ET) ---\n');
    fprintf('%20s %7s %8s %8s %9s\n', 'session', 'n', 'mean', 'median', '%>=75pt');
    for s = ["asia_2000_0000","london_0200_0500","nyam_0930_1100","nypm_1330_1600","other"]
        m = sess == s;
        if any(m)
            fprintf('%20s %7d %8.1f %8.1f %8.0f%%\n', s, sum(m), ...
                mean(amp(m)), median(amp(m)), 100*mean(amp(m)>=75));
        end
    end
    rep.sessionOfLeg = sess;
end

%% ── 3. Higher-timeframe bias, causal ───────────────────────────────────
% Regression slope over the last `biasLen` CLOSED bars of each HTF, mapped
% forward onto 1-min bars. The shift by one HTF bar is what keeps it
% causal: at 10:07 you may only use the 60m bar that closed at 10:00.
biasLen = 20;
b60 = htfBias(t, nq, minutes(60), biasLen);
b15 = htfBias(t, nq, minutes(15), biasLen);
agree = (b60 == b15) & b60 ~= 0;
rep.bias = struct('b60', b60, 'b15', b15, 'agree', agree);

fprintf('\n--- HTF bias coverage ---\n');
fprintf('60m up %.0f%% / down %.0f%%   15m up %.0f%% / down %.0f%%   agree %.0f%% of bars\n', ...
    100*mean(b60>0), 100*mean(b60<0), 100*mean(b15>0), 100*mean(b15<0), 100*mean(agree));

%% ── 4. Fixed-barrier EV grid ───────────────────────────────────────────
% Break-even hit rate for R:R = rr is 1/(1+rr). At 1.5 that is 40%.
beRate = 1/(1+opts.RR);
starts = (1:opts.Step:numel(nq)-opts.Horizon)';

fprintf('\n--- Fixed barriers, R:R = %.2f (break-even hit rate %.1f%%) ---\n', ...
    opts.RR, 100*beRate);
fprintf('Horizon %d bars (%.1f h). Unresolved = neither barrier touched in time.\n', ...
    opts.Horizon, opts.Horizon/60);
fprintf('\n%7s %7s %9s %6s %8s %8s %10s %10s\n', ...
    'stop', 'target', 'contracts', 'dir', 'hit%', 'unres%', 'EV(R)', 'EV($)');

slGrid = [25 37.5 50 75 100];
evRows = table();
for sl = slGrid
    tp   = sl * opts.RR;
    nCon = floor(opts.RiskUSD / (sl * opts.PtValue));
    dollarsPerR = nCon * sl * opts.PtValue;
    for d = [1 -1]
        [hit, loss, unres] = barrierWalk(nq, starts, sl, tp, opts.Horizon, d);
        res  = hit + loss;
        hitR = hit / max(res,1);
        evR  = hitR*opts.RR - (1-hitR)*1.0;
        fprintf('%7.1f %7.1f %9d %6s %8.1f%% %8.1f%% %10.3f %10.0f\n', ...
            sl, tp, nCon, ternary(d>0,'long','short'), 100*hitR, ...
            100*unres/numel(starts), evR, evR*dollarsPerR);
        evRows = [evRows; table(sl, tp, nCon, d, hitR, unres/numel(starts), evR, ...
            evR*dollarsPerR, 'VariableNames', ...
            {'stopPts','tgtPts','contracts','dir','hitRate','unresolved','evR','evUSD'})]; %#ok<AGROW>
    end
end
rep.evGrid = evRows;

%% ── 5. Does HTF bias help? 50/75 only ──────────────────────────────────
sl = 50;  tp = sl*opts.RR;
fprintf('\n--- %g pt stop / %g pt target, split by HTF bias ---\n', sl, tp);
fprintf('%28s %8s %8s %8s %10s\n', 'subset', 'n', 'hit%', 'unres%', 'EV(R)');

subsets = { ...
    'all starts',                true(numel(nq),1),          1; ...
    'long, 60m up',              b60 > 0,                    1; ...
    'long, 60m+15m up (agree)',  agree & b60 > 0,            1; ...
    'long, against 60m',         b60 < 0,                    1; ...
    'short, 60m down',           b60 < 0,                   -1; ...
    'short, 60m+15m dn (agree)', agree & b60 < 0,           -1; ...
    'short, against 60m',        b60 > 0,                   -1};

biasRows = table();
for i = 1:size(subsets,1)
    mask = subsets{i,2};  d = subsets{i,3};
    st   = starts(mask(starts));
    if numel(st) < 50
        continue
    end
    [hit, loss, unres] = barrierWalk(nq, st, sl, tp, opts.Horizon, d);
    res  = hit + loss;
    hitR = hit / max(res,1);
    evR  = hitR*opts.RR - (1-hitR);
    fprintf('%28s %8d %7.1f%% %7.1f%% %10.3f\n', subsets{i,1}, numel(st), ...
        100*hitR, 100*unres/numel(st), evR);
    biasRows = [biasRows; table(string(subsets{i,1}), numel(st), hitR, ...
        unres/numel(st), evR, 'VariableNames', ...
        {'subset','n','hitRate','unresolved','evR'})]; %#ok<AGROW>
end
rep.biasSplit = biasRows;

fprintf('\nBreak-even is %.1f%%. Anything below it loses money at this R:R\n', 100*beRate);
fprintf('before commissions, slippage, and the wicks this close-only test cannot see.\n\n');
end

% ── helpers ────────────────────────────────────────────────────────────
function [bt, o, hi, lo, cl] = resampleOHLC(t, p, step)
%RESAMPLEOHLC Bucket 1-min closes into `step` bars. t must be sorted.
anchor = dateshift(min(t), 'start', 'day');
bin    = floor((t - anchor) ./ step);
[~, ~, gi] = unique(bin);
first = find([true; diff(gi) ~= 0]);
last  = [first(2:end)-1; numel(gi)];
o  = p(first);
cl = p(last);
hi = accumarray(gi, p, [], @max);
lo = accumarray(gi, p, [], @min);
bt = t(first);
end

function [idx, px] = zigzagPivots(hi, lo, k)
%ZIGZAGPIVOTS Fractal pivots, forced to alternate high-low-high.
n = numel(hi);
isH = hi >= movmax(hi, [k k]);
isL = lo <= movmin(lo, [k k]);
isH(1:k) = false;  isH(end-k+1:end) = false;
isL(1:k) = false;  isL(end-k+1:end) = false;

cand = find(isH | isL);
typ  = double(isH(cand)) - double(isL(cand));   % +1 high, -1 low, 0 both
val  = hi(cand).*(typ>=0) + lo(cand).*(typ<0);
typ(typ == 0) = 1;                              % degenerate flat bar -> high

idx = []; px = []; ty = [];
for i = 1:numel(cand)
    if isempty(idx) || typ(i) ~= ty(end)
        idx(end+1,1) = cand(i);  px(end+1,1) = val(i);  ty(end+1,1) = typ(i); %#ok<AGROW>
    else
        % same type twice running: keep the more extreme one
        better = (ty(end) > 0 && val(i) > px(end)) || (ty(end) < 0 && val(i) < px(end));
        if better
            idx(end) = cand(i);  px(end) = val(i);
        end
    end
end
end

function b = htfBias(t, p, step, nBars)
%HTFBIAS Causal +1/-1/0 bias from the regression slope of closed HTF bars.
[bt, ~, ~, ~, cl] = resampleOHLC(t, p, step);
m  = numel(cl);
sl = nan(m,1);
xx = (1:nBars)';
xc = xx - mean(xx);
den = sum(xc.^2);
for i = nBars:m
    y = cl(i-nBars+1:i);
    sl(i) = sum(xc .* (y - mean(y))) / den;
end
% shift one bar: bias at HTF bar i is only usable AFTER it closes
slUse = [NaN; sl(1:end-1)];
sgn   = sign(slUse);
sgn(isnan(sgn)) = 0;
% map each 1-min bar to the HTF bar it falls in
edges = [bt; bt(end)+step];
bi    = discretize(t, edges);
b     = zeros(numel(t),1);
good  = ~isnan(bi);
b(good) = sgn(bi(good));
end

function [hit, loss, unres] = barrierWalk(p, starts, sl, tp, horizon, dir)
%BARRIERWALK First touch of +tp or -sl, on closes, within `horizon` bars.
hit = 0; loss = 0; unres = 0;
for s = starts'
    e  = p(s);
    up = e + tp*(dir>0) + sl*(dir<0);      % dir=+1 -> target above; -1 -> stop above
    dn = e - sl*(dir>0) - tp*(dir<0);
    done = false;
    for j = s+1 : s+horizon
        if p(j) >= up
            if dir > 0, hit = hit + 1; else, loss = loss + 1; end
            done = true; break
        elseif p(j) <= dn
            if dir > 0, loss = loss + 1; else, hit = hit + 1; end
            done = true; break
        end
    end
    if ~done, unres = unres + 1; end
end
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
