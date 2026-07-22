function hist = loadPairHistory(root, cfg, nBars)
%LOADPAIRHISTORY Fetch NQ/ES history with a resolution-aware local cache.
%   Same pattern as replay_demo, but the cache file is keyed by bar
%   resolution so 1-min backtest data never clobbers the 3-min cache.

arguments
    root (1,1) string
    cfg struct
    nBars (1,1) double = 6000
end

res = "3";
if isfield(cfg, 'resolution') && ~isempty(cfg.resolution)
    res = string(cfg.resolution);
end
cacheFile = fullfile(root, 'data', sprintf('history_cache_%sm.mat', res));
maxAgeHours = 12;

useCache = isfile(cacheFile);
if useCache
    info = dir(cacheFile);
    useCache = (now - info.datenum) * 24 < maxAgeHours; %#ok<TNOW1>
end
if useCache
    load(cacheFile, 'hist');
    fprintf('Loaded %d cached %s-min bars (%s)\n', height(hist), res, cacheFile);
else
    feed = TvFeed(cfg);
    hist = feed.getHistory(nBars);
    if ~isfolder(fullfile(root, 'data')), mkdir(fullfile(root, 'data')); end
    save(cacheFile, 'hist');
    fprintf('Fetched and cached %d %s-min bars\n', height(hist), res);
end
end
