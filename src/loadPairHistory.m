function hist = loadPairHistory(root, cfg, nBars, opts)
%LOADPAIRHISTORY Fetch NQ/ES history with a resolution-aware local cache.
%   The cache file is keyed by bar resolution so 1-min backtest data never
%   clobbers the 3-min cache. The cache is EXTENDED in place: bars already
%   on disk are never discarded, freshly fetched bars are merged in by
%   timestamp and win on conflict.
%
%   hist = loadPairHistory(root, cfg)
%   hist = loadPairHistory(root, cfg, nBars, Name=Value)
%
%   Name-value options:
%     Offline      - load the cache regardless of age, never touch the
%                    network. Errors if there is no cache. (default false)
%     MaxAgeHours  - refetch if the cache is older than this (default 12)
%     StartDate    - page history back until it reaches this datetime.
%                    A single request returns only ~5000 bars; paging is
%                    best-effort since anonymous sessions are depth-capped.
%     MaxPages     - safety cap on paging requests (default 40)
%     Force        - refetch even if the cache is fresh (default false)

arguments
    root (1,1) string
    cfg struct
    nBars (1,1) double = 6000
    opts.Offline (1,1) logical = false
    opts.MaxAgeHours (1,1) double = 12
    opts.StartDate datetime = NaT
    opts.MaxPages (1,1) double = 40
    opts.Force (1,1) logical = false
end

res = "3";
if isfield(cfg, 'resolution') && ~isempty(cfg.resolution)
    res = string(cfg.resolution);
end
dataDir = fullfile(root, 'data');
cacheFile = fullfile(dataDir, sprintf('history_cache_%sm.mat', res));

cached = [];
haveCache = isfile(cacheFile);
if haveCache
    S = load(cacheFile, 'hist');
    cached = S.hist;
end

if opts.Offline
    if ~haveCache
        error('loadPairHistory:noCache', ...
            'Offline requested but no cache exists at %s', cacheFile);
    end
    reportSpan('Offline', cached, res);
    hist = cached;
    return
end

% The cache is usable as-is only if it is recent AND already reaches back
% as far as the caller asked for.
useCache = haveCache && ~opts.Force;
if useCache
    info = dir(cacheFile);
    useCache = (now - info.datenum) * 24 < opts.MaxAgeHours; %#ok<TNOW1>
end
if useCache && ~isnat(opts.StartDate)
    useCache = min(cached.Properties.RowTimes) <= localize(opts.StartDate, cached);
end
if useCache
    reportSpan('Cached', cached, res);
    hist = cached;
    return
end

feed = TvFeed(cfg);
fetched = feed.getHistory(nBars, StartDate=opts.StartDate, ...
    MaxPages=opts.MaxPages);

before = 0;
if haveCache, before = height(cached); end
hist = mergeHistory(cached, fetched);

if ~isfolder(dataDir), mkdir(dataDir); end
save(cacheFile, 'hist');
fprintf('Fetched %d bars, merged with %d cached -> %d total\n', ...
    height(fetched), before, height(hist));
reportSpan('Cache now', hist, res);
end

% ----------------------------------------------------------------------
function out = mergeHistory(a, b)
%MERGEHISTORY Union two bar timetables by timestamp; b wins on conflict.
if isempty(a)
    out = sortrows(b);
    return
end
if isempty(b)
    out = sortrows(a);
    return
end
ta = a.Properties.RowTimes;
tb = b.Properties.RowTimes;
if ~isequal(ta.TimeZone, tb.TimeZone)
    b.Properties.RowTimes.TimeZone = ta.TimeZone;
end
out = sortrows([a; b]);
% sortrows is stable, so within a run of equal timestamps the cached row
% comes first and the freshly fetched row last. Keep the last of each run.
rt = out.Properties.RowTimes;
keep = [diff(rt) ~= 0; true];
out = out(keep, :);
end

function d = localize(d, tt)
if isempty(d.TimeZone)
    d.TimeZone = tt.Properties.RowTimes.TimeZone;
end
end

function reportSpan(label, tt, res)
rt = tt.Properties.RowTimes;
fprintf('%s: %d %s-min bars, %s -> %s\n', label, height(tt), res, ...
    string(min(rt)), string(max(rt)));
end
