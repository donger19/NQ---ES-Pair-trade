classdef TvFeed < handle
    %TVFEED MATLAB bridge to the TradingView websocket feed (python/tvfeed.py).
    %   Fetches historical bars and streams live bars for the NQ/ES pair,
    %   returning timestamp-aligned close prices as timetables.

    properties (SetAccess = private)
        SymbolNQ (1,1) string
        SymbolES (1,1) string
        Resolution (1,1) string
        Token (1,1) string
        ResolutionSeconds (1,1) double
    end

    properties (Access = private)
        BarsNQ containers.Map   % unix ts -> [ts o h l c v]
        BarsES containers.Map
        LiveStarted (1,1) logical = false
    end

    methods
        function obj = TvFeed(cfg)
            arguments
                cfg struct = struct()
            end
            obj.SymbolNQ = getFieldOr(cfg, 'symbolNQ', "CME_MINI:NQ1!");
            obj.SymbolES = getFieldOr(cfg, 'symbolES', "CME_MINI:ES1!");
            obj.Resolution = string(getFieldOr(cfg, 'resolution', "3"));
            obj.Token = string(getFieldOr(cfg, 'tradingviewToken', ""));
            obj.ResolutionSeconds = 60 * str2double(obj.Resolution);
            obj.BarsNQ = containers.Map('KeyType', 'double', 'ValueType', 'any');
            obj.BarsES = containers.Map('KeyType', 'double', 'ValueType', 'any');
            TvFeed.ensurePython();
        end

        function tt = getHistory(obj, nBars, opts)
            %GETHISTORY Fetch historical bars as an aligned timetable.
            %   nBars is the per-page depth. Pass StartDate to page
            %   backwards past the single-request limit (a create_series
            %   alone returns ~5000 bars); paging is best-effort because
            %   anonymous sessions are depth-capped server-side.
            arguments
                obj
                nBars (1,1) double = 5000
                opts.StartDate datetime = NaT
                opts.MaxPages (1,1) double = 40
            end
            startTs = 0;
            if ~isnat(opts.StartDate)
                d = opts.StartDate;
                if isempty(d.TimeZone)
                    d.TimeZone = 'America/New_York';
                end
                startTs = floor(posixtime(d));
            end
            raw = char(py.tvfeed.fetch_history_json( ...
                obj.symbolsCsv(), char(obj.Resolution), int32(nBars), ...
                obj.tokenArg(), int64(startTs), int32(opts.MaxPages)));
            data = jsondecode(raw);
            fn = fieldnames(data);
            for k = 1:numel(fn)
                sym = fn{k};
                bars = data.(sym);
                if contains(sym, 'NQ')
                    obj.mergeBars(obj.BarsNQ, bars);
                else
                    obj.mergeBars(obj.BarsES, bars);
                end
            end
            tt = obj.alignedRows(cell2mat(keys(obj.BarsNQ)));
        end

        function startLive(obj, nBars)
            arguments
                obj
                nBars (1,1) double = 300
            end
            py.tvfeed.start(obj.symbolsCsv(), char(obj.Resolution), ...
                int32(nBars), obj.tokenArg());
            obj.LiveStarted = true;
        end

        function [tt, st] = poll(obj)
            %POLL Pull buffered live updates; returns aligned rows whose
            %   values changed since the last poll, plus feed status.
            newNQ = jsondecode(char(py.tvfeed.get_bars_json(char(obj.SymbolNQ))));
            newES = jsondecode(char(py.tvfeed.get_bars_json(char(obj.SymbolES))));
            changedTs = [];
            if ~isempty(newNQ)
                obj.mergeBars(obj.BarsNQ, newNQ);
                changedTs = [changedTs; newNQ(:,1)];
            end
            if ~isempty(newES)
                obj.mergeBars(obj.BarsES, newES);
                changedTs = [changedTs; newES(:,1)];
            end
            tt = obj.alignedRows(unique(changedTs));
            st = jsondecode(char(py.tvfeed.status_json()));
        end

        function stopLive(obj)
            if obj.LiveStarted
                py.tvfeed.stop();
                obj.LiveStarted = false;
            end
        end

        function delete(obj)
            obj.stopLive();
        end
    end

    methods (Access = private)
        function csv = symbolsCsv(obj)
            csv = char(obj.SymbolNQ + "," + obj.SymbolES);
        end

        function tok = tokenArg(obj)
            if strlength(obj.Token) > 0
                tok = char(obj.Token);
            else
                tok = 'unauthorized_user_token';
            end
        end

        function tt = alignedRows(obj, tsList)
            %ALIGNEDROWS Timetable of rows (Time, NQ, ES closes) for the
            %   given timestamps where both symbols have a bar.
            tsList = tsList(:);
            ok = arrayfun(@(t) isKey(obj.BarsNQ, t) && isKey(obj.BarsES, t), tsList);
            tsList = sort(tsList(ok));
            n = numel(tsList);
            nq = zeros(n, 1);
            es = zeros(n, 1);
            for k = 1:n
                bNQ = obj.BarsNQ(tsList(k));
                bES = obj.BarsES(tsList(k));
                nq(k) = bNQ(5);   % close
                es(k) = bES(5);
            end
            t = datetime(tsList, 'ConvertFrom', 'posixtime', ...
                'TimeZone', 'America/New_York');
            tt = timetable(t, nq, es, 'VariableNames', {'NQ', 'ES'});
        end
    end

    methods (Static)
        function mergeBars(map, bars)
            % bars: n x 6 matrix [ts o h l c v]
            for k = 1:size(bars, 1)
                map(bars(k, 1)) = bars(k, :);
            end
        end

        function ensurePython()
            here = fileparts(fileparts(mfilename('fullpath')));
            pydir = fullfile(here, 'python');
            pypath = py.sys.path;
            found = any(cellfun(@(p) strcmp(string(p), pydir), cell(pypath)));
            if ~found
                insert(pypath, int32(0), pydir);
            end
            mod = py.importlib.import_module('tvfeed');
            py.importlib.reload(mod);
        end
    end
end

function v = getFieldOr(s, name, default)
if isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
else
    v = default;
end
end
