classdef PairDashboard < handle
    %PAIRDASHBOARD Live NQ-ES pair model dashboard.
    %   NQ_t = alpha_t + beta_t * ES_t + e_t
    %   Kalman-filtered alpha/beta, residual z-score, and Markov-switching
    %   regime probability, updating live from the TradingView feed.
    %
    %   Model outputs only - no trade signals.

    properties (SetAccess = private)
        Cfg struct
        Feed TvFeed
        KF KalmanHedge
        Regime RegimeDetector
    end

    properties (Access = private)
        Fig
        UpdateTimer
        Tiles struct = struct()
        Lines struct = struct()
        Axes struct = struct()
        % rolling display history
        T (:,1) datetime
        NQ (:,1) double
        Pred (:,1) double
        Z (:,1) double
        BetaH (:,1) double
        AlphaH (:,1) double
        PVol (:,1) double
        MaxPoints (1,1) double = 2000
        % live bar bookkeeping
        Pending containers.Map          % posix ts -> [nq es] awaiting close
        LastClosedTs (1,1) double = 0
        ResSec (1,1) double = 180
    end

    methods
        function obj = PairDashboard(cfg)
            arguments
                cfg struct = struct()
            end
            obj.Cfg = cfg;
            obj.Pending = containers.Map('KeyType','double','ValueType','any');
            obj.T = datetime.empty(0,1);
            obj.T.TimeZone = 'America/New_York';
            obj.buildUI();
            drawnow;
            try
                obj.initModel();
                obj.startLive();
            catch ME
                obj.setStatus("ERROR: " + ME.message, [0.85 0.2 0.2]);
                rethrow(ME);
            end
        end

        function delete(obj)
            obj.shutdown();
        end
    end

    % ------------------------------------------------------------------
    % Startup
    % ------------------------------------------------------------------
    methods (Access = private)
        function initModel(obj)
            cfg = obj.Cfg;
            obj.setStatus("Fetching history...", [0.93 0.69 0.13]);
            drawnow;
            obj.Feed = TvFeed(cfg);
            obj.ResSec = obj.Feed.ResolutionSeconds;
            nBars = getOr(cfg, 'historyBars', 5000);
            warmN = getOr(cfg, 'warmupBars', 1000);
            hist = obj.Feed.getHistory(nBars);
            if height(hist) < warmN + 100
                error('Not enough history (%d bars) for warm-up.', height(hist));
            end

            obj.setStatus("Warming up Kalman filter...", [0.93 0.69 0.13]);
            drawnow;
            obj.KF = KalmanHedge();
            obj.KF.Delta = getOr(cfg, 'kalmanDelta', 1e-5);
            obj.KF.ZWindow = getOr(cfg, 'zWindow', 60);
            obj.KF.warmStart(hist.NQ(1:warmN), hist.ES(1:warmN));

            % replay history through the filter; the newest bar may still
            % be forming (and on a delayed feed wall-clock time cannot
            % tell), so the last bar is always left to the live loop
            n = height(hist);
            resid = nan(n,1);
            for k = warmN+1:n-1
                out = obj.KF.update(hist.NQ(k), hist.ES(k));
                resid(k) = out.residual;
                obj.appendPoint(hist.t(k), hist.NQ(k), out, NaN);
            end
            obj.LastClosedTs = posixtime(hist.t(n-1));

            obj.setStatus("Fitting regime model...", [0.93 0.69 0.13]);
            drawnow;
            obj.Regime = RegimeDetector();
            obj.Regime.Window = getOr(cfg, 'regimeWindow', 400);
            idx = find(~isnan(resid));
            obj.Regime.fit(resid(idx));
            p = obj.Regime.smoothAll(resid(idx));
            m = min(numel(p), numel(obj.PVol));
            obj.PVol(end-m+1:end) = p(end-m+1:end);

            obj.redrawCharts();
            obj.refreshTiles(obj.lastOut(hist), obj.Regime.current(), true);
        end

        function out = lastOut(obj, hist)
            out = obj.KF.predictOnly(hist.NQ(end), hist.ES(end));
            out.actualNQ = hist.NQ(end);
        end

        function startLive(obj)
            obj.Feed.startLive(50);
            period = getOr(obj.Cfg, 'pollSeconds', 3);
            obj.UpdateTimer = timer( ...
                'ExecutionMode', 'fixedSpacing', ...
                'Period', period, ...
                'BusyMode', 'drop', ...
                'TimerFcn', @(~,~) obj.onTick());
            start(obj.UpdateTimer);
            obj.setStatus("Live", [0.28 0.7 0.32]);
        end

        % --------------------------------------------------------------
        % Live tick
        % --------------------------------------------------------------
        function onTick(obj)
            try
                [rows, st] = obj.Feed.poll();
                for k = 1:height(rows)
                    ts = posixtime(rows.t(k));
                    obj.Pending(ts) = [rows.NQ(k), rows.ES(k)];
                end
                obj.processPending();
                obj.updateStatusTile(st);
            catch ME
                obj.setStatus("ERROR: " + ME.message, [0.85 0.2 0.2]);
            end
        end

        function processPending(obj)
            if isempty(obj.Pending) || obj.Pending.Count == 0
                return
            end
            % a bar is closed once a bar with a newer timestamp exists -
            % works for both realtime and delayed feeds (wall-clock rules
            % misfire on delayed data)
            tsAll = sort(cell2mat(keys(obj.Pending)));
            maxTs = tsAll(end);
            newClosed = false;
            rg = obj.Regime.current();
            for ts = tsAll
                bar = obj.Pending(ts);
                if ts < maxTs
                    % closed bar
                    remove(obj.Pending, ts);
                    if ts <= obj.LastClosedTs
                        continue   % already processed (history overlap)
                    end
                    out = obj.KF.update(bar(1), bar(2));
                    rg = obj.Regime.step(out.residual);
                    t = datetime(ts, 'ConvertFrom', 'posixtime', ...
                        'TimeZone', 'America/New_York');
                    obj.appendPoint(t, bar(1), out, rg.probVolatile);
                    obj.LastClosedTs = ts;
                    newClosed = true;
                    out.actualNQ = bar(1);
                    obj.refreshTiles(out, rg, true);
                else
                    % forming bar: display only, never update the filter
                    out = obj.KF.predictOnly(bar(1), bar(2));
                    out.actualNQ = bar(1);
                    obj.refreshTiles(out, rg, false);
                end
            end
            if newClosed
                obj.redrawCharts();
            end
        end

        % --------------------------------------------------------------
        % Display state
        % --------------------------------------------------------------
        function appendPoint(obj, t, nqActual, out, pVol)
            obj.T(end+1,1) = t;
            obj.NQ(end+1,1) = nqActual;
            obj.Pred(end+1,1) = out.predictedNQ;
            obj.Z(end+1,1) = out.zScore;
            obj.BetaH(end+1,1) = out.beta;
            obj.AlphaH(end+1,1) = out.alpha;
            obj.PVol(end+1,1) = pVol;
            if numel(obj.T) > obj.MaxPoints
                obj.T = obj.T(end-obj.MaxPoints+1:end);
                obj.NQ = obj.NQ(end-obj.MaxPoints+1:end);
                obj.Pred = obj.Pred(end-obj.MaxPoints+1:end);
                obj.Z = obj.Z(end-obj.MaxPoints+1:end);
                obj.BetaH = obj.BetaH(end-obj.MaxPoints+1:end);
                obj.AlphaH = obj.AlphaH(end-obj.MaxPoints+1:end);
                obj.PVol = obj.PVol(end-obj.MaxPoints+1:end);
            end
        end

        function redrawCharts(obj)
            set(obj.Lines.nqActual, 'XData', obj.T, 'YData', obj.NQ);
            set(obj.Lines.nqPred, 'XData', obj.T, 'YData', obj.Pred);
            set(obj.Lines.z, 'XData', obj.T, 'YData', obj.Z);
            set(obj.Lines.pvol, 'XData', obj.T, 'YData', obj.PVol);
            set(obj.Lines.beta, 'XData', obj.T, 'YData', obj.BetaH);
            set(obj.Lines.alpha, 'XData', obj.T, 'YData', obj.AlphaH);
        end

        function refreshTiles(obj, out, rg, isClosed)
            fmtPts = @(v) sprintf('%.2f', v);
            obj.Tiles.nq.Text = fmtPts(out.actualNQ);
            obj.Tiles.pred.Text = fmtPts(out.predictedNQ);
            obj.Tiles.resid.Text = sprintf('%+.2f', out.residual);
            obj.Tiles.z.Text = sprintf('%+.2f', out.zScore);
            obj.Tiles.beta.Text = sprintf('%.4f', out.beta);
            obj.Tiles.alpha.Text = sprintf('%.1f', out.alpha);
            obj.Tiles.regime.Text = sprintf('%s (%.0f%%)', rg.label, ...
                100 * max(rg.probVolatile, 1 - rg.probVolatile));
            if rg.probVolatile >= 0.5
                obj.Tiles.regime.FontColor = [0.85 0.33 0.1];
            else
                obj.Tiles.regime.FontColor = [0.28 0.7 0.32];
            end
            % z-score tile color: highlight stretched residuals
            az = abs(out.zScore);
            if az >= 2
                obj.Tiles.z.FontColor = [0.85 0.2 0.2];
            elseif az >= 1
                obj.Tiles.z.FontColor = [0.93 0.69 0.13];
            else
                obj.Tiles.z.FontColor = [0.1 0.1 0.1];
            end
            if isClosed
                obj.Tiles.barState.Text = 'closed bar';
            else
                obj.Tiles.barState.Text = 'forming bar';
            end
        end

        function updateStatusTile(obj, st)
            if st.connected
                if st.authorized
                    src = "Live (realtime)";
                else
                    src = "Live (delayed feed)";
                end
                obj.setStatus(sprintf('%s | last msg %.0fs ago', ...
                    src, st.last_msg_age_s), [0.28 0.7 0.32]);
            else
                obj.setStatus("Reconnecting... " + string(st.last_error), ...
                    [0.85 0.33 0.1]);
            end
        end

        function setStatus(obj, txt, color)
            obj.Tiles.status.Text = char(txt);
            obj.Tiles.status.FontColor = color;
        end

        % --------------------------------------------------------------
        % UI construction
        % --------------------------------------------------------------
        function buildUI(obj)
            obj.Fig = uifigure('Name', 'NQ-ES Pair Model (Kalman + Regime)', ...
                'Position', [60 60 1350 860], ...
                'CloseRequestFcn', @(~,~) obj.shutdown());
            gl = uigridlayout(obj.Fig, [3 1]);
            gl.RowHeight = {78, 26, '1x'};

            % --- tile row ---
            tileGrid = uigridlayout(gl, [1 8]);
            tileGrid.Layout.Row = 1;
            tileGrid.ColumnWidth = repmat({'1x'}, 1, 8);
            tileGrid.Padding = [4 2 4 2];
            names = {'nq', 'pred', 'resid', 'z', 'beta', 'alpha', 'regime', 'barState'};
            titles = {'NQ actual', 'NQ predicted', 'Residual', ...
                'Residual z-score', 'Hedge ratio (beta)', 'Intercept (alpha)', ...
                'Regime', 'Bar'};
            for k = 1:numel(names)
                p = uipanel(tileGrid);
                pg = uigridlayout(p, [2 1]);
                pg.RowHeight = {16, '1x'};
                pg.Padding = [6 2 6 2];
                lblT = uilabel(pg, 'Text', titles{k}, 'FontSize', 11, ...
                    'FontColor', [0.45 0.45 0.5]);
                lblT.Layout.Row = 1;
                lblV = uilabel(pg, 'Text', '-', 'FontSize', 20, ...
                    'FontWeight', 'bold');
                lblV.Layout.Row = 2;
                obj.Tiles.(names{k}) = lblV;
            end

            % --- status bar ---
            obj.Tiles.status = uilabel(gl, 'Text', 'Starting...', ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'FontColor', [0.93 0.69 0.13]);
            obj.Tiles.status.Layout.Row = 2;

            % --- charts ---
            chartGrid = uigridlayout(gl, [4 1]);
            chartGrid.Layout.Row = 3;
            chartGrid.Padding = [0 0 0 0];
            chartGrid.RowSpacing = 4;

            % timezone-aware empty seed so rulers accept feed timestamps
            t0 = datetime.empty(0,1);
            t0.TimeZone = 'America/New_York';

            ax1 = uiaxes(chartGrid);
            obj.Lines.nqActual = plot(ax1, t0, zeros(0,1), ...
                'Color', [0.3 0.3 0.35], 'DisplayName', 'NQ actual');
            hold(ax1, 'on');
            obj.Lines.nqPred = plot(ax1, t0, zeros(0,1), ...
                'Color', [0.85 0.33 0.1], 'DisplayName', 'NQ predicted');
            title(ax1, 'Actual vs Kalman-predicted NQ');
            legend(ax1, 'Location', 'northwest');
            grid(ax1, 'on');

            ax2 = uiaxes(chartGrid);
            yyaxis(ax2, 'right');
            obj.Lines.pvol = area(ax2, t0, zeros(0,1), ...
                'FaceColor', [0.93 0.69 0.13], 'FaceAlpha', 0.18, ...
                'EdgeColor', 'none', 'DisplayName', 'P(volatile)');
            ylim(ax2, [0 1]);
            ylabel(ax2, 'P(volatile)');
            ax2.YAxis(2).Color = [0.93 0.69 0.13];
            yyaxis(ax2, 'left');
            obj.Lines.z = plot(ax2, t0, zeros(0,1), ...
                'Color', [0 0.45 0.74], 'DisplayName', 'residual z');
            yline(ax2, [-2 -1 0 1 2], ':', 'Color', [0.55 0.55 0.55], ...
                'HandleVisibility', 'off');
            title(ax2, 'Residual z-score & regime probability');
            grid(ax2, 'on');

            ax3 = uiaxes(chartGrid);
            obj.Lines.beta = plot(ax3, t0, zeros(0,1), ...
                'Color', [0.47 0.67 0.19]);
            title(ax3, 'Hedge ratio \beta');
            grid(ax3, 'on');

            ax4 = uiaxes(chartGrid);
            obj.Lines.alpha = plot(ax4, t0, zeros(0,1), ...
                'Color', [0.49 0.18 0.56]);
            title(ax4, 'Intercept \alpha');
            grid(ax4, 'on');

            obj.Axes = struct('ax1', ax1, 'ax2', ax2, 'ax3', ax3, 'ax4', ax4);
            linkaxes([ax1 ax3 ax4], 'x');
        end

        function shutdown(obj)
            if ~isempty(obj.UpdateTimer) && isvalid(obj.UpdateTimer)
                stop(obj.UpdateTimer);
                delete(obj.UpdateTimer);
            end
            if ~isempty(obj.Feed) && isvalid(obj.Feed)
                obj.Feed.stopLive();
            end
            if ~isempty(obj.Fig) && isvalid(obj.Fig)
                delete(obj.Fig);
            end
        end
    end
end

function v = getOr(s, name, default)
if isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
else
    v = default;
end
end
