classdef SignalEngine < handle
    %SIGNALENGINE Bar-close mirror of the Pine v3 signal state machine.
    %   Validation/backtest use only - not a live trader. Consumes one
    %   closed bar of model features per step() and reproduces the exact
    %   rule semantics of pine/nq_es_pair.pine so backtest conclusions
    %   transfer to the chart the user trades from.
    %
    %   States: 0 FLAT, 1 CONVERGENCE_ARMED, 2 SIGNAL_PENDING,
    %           3 IN_POSITION, 4 TP_ZONE, 5 REVERSAL_ELIGIBLE
    %   dir:    +1 long NQ / short ES, -1 short NQ / long ES

    properties (SetAccess = private)
        P struct              % rule parameters (config.json "signal" block)
        State (1,1) double = 0
        Dir (1,1) double = 0
        Trades struct = struct([])   % closed-trade log with R multiples
    end

    properties (Access = private)
        PendType (1,1) double = 0    % 1 = z-fade breach, 2 = trend-cross
        ConfirmCount (1,1) double = 0
        ConsolCount (1,1) double = 0
        EntryZ (1,1) double = NaN
        EntryPx (1,1) double = NaN
        EntrySd (1,1) double = NaN
        EntryT datetime = NaT
        EntrySize struct = struct()
        EntryFade (1,1) logical = false   % true = z-fade entry (rule 1 gate)
        EntryEs (1,1) double = NaN
        EntryBeta (1,1) double = NaN
        EntryStopPts (1,1) double = NaN
        % fair value frozen at the breach bar: closed-bar innovations are
        % near-white (the filter absorbs each spike immediately), so
        % confirmation must ask "is PRICE still stretched vs the fair value
        % at spike time?" - the same quantity the live forming-bar z shows
        FrozenA (1,1) double = NaN
        FrozenB (1,1) double = NaN
        FrozenSd (1,1) double = NaN
        % rolling feature history (newest last)
        Zh (:,1) double = zeros(0,1)
        NQh (:,1) double = zeros(0,1)
        Gaph (:,1) double = zeros(0,1)
        XFlags (:,1) logical = false(0,1)   % z zero-crossing flags
        PrevNormNQ (1,1) double = NaN
        PrevNormES (1,1) double = NaN
        MaxHist (1,1) double = 600
    end

    methods
        function obj = SignalEngine(sigCfg)
            arguments
                sigCfg struct = struct()
            end
            d = SignalEngine.defaults();
            fn = fieldnames(d);
            for k = 1:numel(fn)
                if isfield(sigCfg, fn{k}) && ~isempty(sigCfg.(fn{k}))
                    d.(fn{k}) = sigCfg.(fn{k});
                end
            end
            obj.P = d;
        end

        function out = step(obj, bar)
            %STEP Process one CLOSED bar of features.
            %   bar: struct with t, nq, es, z, resSd, beta, normNQ, normES,
            %        esSlope, pVol. Mirrors the barstate.isconfirmed block.
            p = obj.P;
            out = obj.emptyEvents();

            % --- rolling features (mirror the Pine global-scope series) ---
            obj.Zh(end+1,1) = bar.z;
            obj.NQh(end+1,1) = bar.nq;
            gap = bar.normNQ - bar.normES;
            obj.Gaph(end+1,1) = gap;
            nZ = numel(obj.Zh);
            xf = false;
            if nZ >= 2
                z1 = obj.Zh(end); z0 = obj.Zh(end-1);
                xf = (z1 > 0 && z0 <= 0) || (z1 < 0 && z0 >= 0);
            end
            obj.XFlags(end+1,1) = xf;
            obj.trimHistory();

            % momentum (rule 2): unsettled until enough history exists
            momentumSettled = false;
            if nZ > p.velBars
                zVel = obj.Zh(end) - obj.Zh(end-p.velBars);
                nqRoc = 100 * (obj.NQh(end) / obj.NQh(end-p.velBars) - 1);
                momentumSettled = abs(zVel) <= p.zVelMax && abs(nqRoc) <= p.rocMax;
            end

            % chop (rule 3)
            w = min(p.chopWindow, nZ);
            isChop = sum(obj.XFlags(end-w+1:end)) >= p.chopReversals && ...
                max(abs(obj.Zh(end-w+1:end))) < p.chopBand;

            % convergence / intertwine / cross (rules 5-6)
            gapAbs = abs(gap);
            converging = false;
            if numel(obj.Gaph) > p.convBars
                converging = gapAbs < p.armDist && ...
                    gapAbs < abs(obj.Gaph(end-p.convBars));
            end
            wi = min(p.intertwineBars, numel(obj.Gaph));
            intertwined = max(abs(obj.Gaph(end-wi+1:end))) < p.intertwineBand && ...
                numel(obj.Gaph) >= p.intertwineBars;
            crossUp = ~isnan(obj.PrevNormNQ) && bar.normNQ > bar.normES && ...
                obj.PrevNormNQ <= obj.PrevNormES;
            crossDn = ~isnan(obj.PrevNormNQ) && bar.normNQ < bar.normES && ...
                obj.PrevNormNQ >= obj.PrevNormES;
            trendCross = crossUp || crossDn;
            obj.PrevNormNQ = bar.normNQ;
            obj.PrevNormES = bar.normES;

            % directional context: neutral regime band = stand down
            if bar.pVol >= 0.40 && bar.pVol <= 0.60
                contextDir = 0;                    % neutral regime: stand down
            else
                contextDir = sign(bar.esSlope);    % <0 bearish -> short NQ / long ES
            end
            isCalm = bar.pVol < 0.5;
            alertOk = ~p.calmOnly || isCalm;

            if isnan(bar.z) || isnan(bar.resSd) || bar.resSd <= 0
                out.state = obj.State; out.dir = obj.Dir;
                out.stateName = obj.stateName();
                return
            end

            % fade candidate (rule 1 gate; no fades beyond the hard stop, rule 2)
            if abs(bar.z) >= p.zHardStop
                breachDir = 0;
            elseif bar.z >= p.entryZ
                breachDir = -1;
            elseif bar.z <= -p.entryZ
                breachDir = 1;
            else
                breachDir = 0;
            end

            % --- state machine (mirrors the Pine transitions exactly) -----
            switch obj.State
                case 0   % FLAT
                    if breachDir ~= 0 && alertOk && ~isChop
                        obj.State = 2; obj.Dir = breachDir;
                        obj.PendType = 1; obj.ConfirmCount = 0;
                        obj.freezeFair(bar);
                        out.signal = "pending";
                    elseif contextDir ~= 0 && ~isChop && (converging || intertwined)
                        obj.State = 1; obj.Dir = contextDir;
                        out.signal = "armed";
                    end

                case 1   % CONVERGENCE_ARMED
                    if isChop || contextDir == 0 || contextDir ~= obj.Dir
                        obj.State = 0; obj.Dir = 0;
                    elseif breachDir ~= 0 && alertOk
                        obj.State = 2; obj.Dir = breachDir;
                        obj.PendType = 1; obj.ConfirmCount = 0;
                        obj.freezeFair(bar);
                        out.signal = "pending";
                    elseif (obj.Dir == -1 && crossUp) || (obj.Dir == 1 && crossDn)
                        % directional trigger only: bearish = NQ crossing UP
                        % into ES ("NQ trades up to ES; once they cross, NQ
                        % sells off hard"); bullish is the mirror
                        obj.State = 2; obj.PendType = 2; obj.ConfirmCount = 0;
                        obj.freezeFair(bar);
                        out.signal = "pending";
                    elseif ~(converging || intertwined)
                        obj.State = 0; obj.Dir = 0;
                    end

                case 2   % SIGNAL_PENDING (rule 2 confirmation)
                    obj.ConfirmCount = obj.ConfirmCount + 1;
                    zHold = obj.zHold(bar);   % stretch vs the frozen fair value
                    if obj.PendType == 1
                        if obj.Dir == -1
                            stillValid = zHold >= p.entryZ && zHold < p.zHardStop;
                        else
                            stillValid = zHold <= -p.entryZ && zHold > -p.zHardStop;
                        end
                    else
                        stillValid = contextDir == obj.Dir;
                    end
                    if isChop || ~stillValid
                        obj.State = 0; obj.Dir = 0; obj.PendType = 0;
                        out.signal = "disarmed";
                    elseif obj.ConfirmCount >= p.confirmBars && momentumSettled
                        aligned = strcmp(p.gapDir, 'none') || ...
                            (obj.Dir == 1 && strcmp(p.gapDir, 'up')) || ...
                            (obj.Dir == -1 && strcmp(p.gapDir, 'down'));
                        if ~aligned && strcmp(p.gapPolicy, 'block')
                            obj.State = 0; obj.Dir = 0; obj.PendType = 0;
                            out.signal = "gap_blocked";
                        else
                            sizeMult = 1;
                            if ~aligned && strcmp(p.gapPolicy, 'half')
                                sizeMult = 0.5;
                            end
                            obj.enterPosition(bar, sizeMult);
                            out.signal = "enter";
                        end
                    end

                case 3   % IN_POSITION
                    rBar = obj.rFromBar(bar);   % pair P&L in R (price-based)
                    if obj.Dir == 1, advCross = crossDn; else, advCross = crossUp; end
                    % z-reversion TP only applies to fade entries taken
                    % beyond the gate, and is measured against the frozen
                    % entry fair value: "price actually reverted", not the
                    % self-resetting rolling innovation
                    zHold = obj.zHold(bar);
                    if ~obj.EntryFade
                        zReverted = false;
                    elseif obj.Dir == -1
                        zReverted = zHold <= p.zExit;
                    else
                        zReverted = zHold >= -p.zExit;
                    end
                    if abs(bar.z) < p.consolBand
                        obj.ConsolCount = obj.ConsolCount + 1;
                    else
                        obj.ConsolCount = 0;
                    end
                    if rBar <= -1.0 || abs(bar.z) >= p.zHardStop
                        obj.closeTrade(bar, rBar, "stop");
                        obj.State = 0; obj.Dir = 0;
                        out.signal = "stop"; out.rExit = rBar;
                    elseif advCross
                        obj.State = 5;
                        out.signal = "reversal_eligible";
                    elseif rBar >= obj.tpR() || zReverted
                        obj.closeTrade(bar, rBar, "tp");
                        obj.State = 4;
                        out.signal = "exit"; out.rExit = rBar;
                    elseif obj.ConsolCount >= p.consolBars
                        obj.closeTrade(bar, rBar, "consolidation");
                        obj.State = 0; obj.Dir = 0;
                        out.signal = "exit"; out.rExit = rBar;
                    elseif isChop
                        obj.closeTrade(bar, rBar, "chop");
                        obj.State = 0; obj.Dir = 0;
                        out.signal = "exit"; out.rExit = rBar;
                    end

                case 4   % TP_ZONE (target hit last bar; go flat)
                    obj.State = 0; obj.Dir = 0;

                case 5   % REVERSAL_ELIGIBLE
                    rBar = obj.rFromBar(bar);
                    obj.closeTrade(bar, rBar, "reversal");
                    obj.State = 0; obj.Dir = 0;
                    out.signal = "exit"; out.rExit = rBar;
            end

            out.state = obj.State;
            out.stateName = obj.stateName();
            out.dir = obj.Dir;
            out.isChop = isChop;
            out.momentumSettled = momentumSettled;
            out.contextDir = contextDir;
        end

        function name = stateName(obj)
            names = ["FLAT", "CONVERGENCE_ARMED", "SIGNAL_PENDING", ...
                "IN_POSITION", "TP_ZONE", "REVERSAL_ELIGIBLE"];
            name = names(obj.State + 1);
        end

        function tbl = tradeTable(obj)
            %TRADETABLE Closed trades as a MATLAB table (empty-safe).
            if isempty(obj.Trades)
                tbl = table();
            else
                tbl = struct2table(obj.Trades, 'AsArray', true);
            end
        end
    end

    methods (Access = private)
        function enterPosition(obj, bar, sizeMult)
            p = obj.P;
            obj.EntryZ = obj.zHold(bar);   % stretch vs frozen fair at entry
            obj.EntryPx = bar.nq;
            obj.EntryEs = bar.es;
            obj.EntryBeta = obj.FrozenB;
            obj.EntrySd = obj.FrozenSd;
            obj.EntryT = bar.t;
            obj.EntryFade = obj.PendType == 1;
            obj.ConsolCount = 0;
            obj.EntryStopPts = p.stopZ * bar.resSd;
            obj.EntrySize = SignalEngine.positionSize( ...
                p.maxRiskUSD * sizeMult, obj.EntryStopPts, bar.beta, p);
            obj.State = 3;
        end

        function freezeFair(obj, bar)
            %FREEZEFAIR Pin the fair value at the breach/trigger bar.
            %   Derived so that zHold at this bar equals the current z
            %   (absorbs the rolling residual mean).
            obj.FrozenB = bar.beta;
            obj.FrozenSd = bar.resSd;
            obj.FrozenA = bar.nq - bar.z * bar.resSd - bar.beta * bar.es;
        end

        function z = zHold(obj, bar)
            %ZHOLD Price stretch vs the frozen fair value, in entry sigmas.
            z = (bar.nq - (obj.FrozenA + obj.FrozenB * bar.es)) / obj.FrozenSd;
        end

        function r = rFromBar(obj, bar)
            %RFROMBAR Live R multiple from pair price movement (real P&L
            %   proxy: NQ leg minus beta-scaled ES leg, in NQ points).
            resDelta = (bar.nq - obj.EntryPx) - ...
                obj.EntryBeta * (bar.es - obj.EntryEs);
            r = obj.Dir * resDelta / obj.EntryStopPts;
        end

        function closeTrade(obj, bar, rMult, reason)
            if obj.EntryFade
                entryType = "fade";
            else
                entryType = "convergence";
            end
            tr = struct( ...
                'entryTime', obj.EntryT, ...
                'exitTime', bar.t, ...
                'dir', obj.Dir, ...
                'entryZ', obj.EntryZ, ...
                'exitZ', bar.z, ...
                'entryPx', obj.EntryPx, ...
                'exitPx', bar.nq, ...
                'rMultiple', rMult, ...
                'exitReason', string(reason), ...
                'entryType', entryType, ...
                'riskUSD', obj.EntrySize.riskUsed, ...
                'pnlUSD', rMult * obj.EntrySize.riskUsed, ...
                'sizeText', obj.EntrySize.text);
            if isempty(obj.Trades)
                obj.Trades = tr;
            else
                obj.Trades(end+1) = tr;
            end
            obj.EntryZ = NaN; obj.EntryPx = NaN; obj.EntrySd = NaN;
            obj.EntryEs = NaN; obj.EntryBeta = NaN; obj.EntryStopPts = NaN;
            obj.EntryT = NaT; obj.EntrySize = struct();
        end

        function r = tpR(obj)
            m = string(obj.P.tpMode);
            if contains(m, "2")
                r = 2.0;
            else
                r = 1.0;
            end
        end

        function trimHistory(obj)
            if numel(obj.Zh) > obj.MaxHist
                obj.Zh = obj.Zh(end-obj.MaxHist+1:end);
                obj.NQh = obj.NQh(end-obj.MaxHist+1:end);
                obj.Gaph = obj.Gaph(end-obj.MaxHist+1:end);
                obj.XFlags = obj.XFlags(end-obj.MaxHist+1:end);
            end
        end

        function out = emptyEvents(obj) %#ok<MANU>
            out = struct('state', 0, 'stateName', "FLAT", 'dir', 0, ...
                'signal', "", 'rExit', NaN, 'isChop', false, ...
                'momentumSettled', false, 'contextDir', 0);
        end
    end

    methods (Static)
        function s = positionSize(maxRiskUSD, stopPts, beta, p)
            %POSITIONSIZE Contracts from $ risk and stop distance (rule 4).
            %   Risk per 1 NQ pair-lot ~ stopPts * $/pt(NQ); the beta-scaled
            %   ES leg hedges the common move. Falls back to micros when
            %   even 1 NQ exceeds the risk budget.
            if stopPts <= 0
                s = struct('nNQ', 0, 'nES', 0, 'nMNQ', 0, 'nMES', 0, ...
                    'useMicros', false, 'riskUsed', 0, 'text', "no size");
                return
            end
            nNQ = floor(maxRiskUSD / (stopPts * p.ptValueNQ));
            nMNQ = floor(maxRiskUSD / (stopPts * p.ptValueMNQ));
            useMicros = nNQ < 1;
            nES = max(1, round(nNQ * beta * p.ptValueNQ / p.ptValueES));
            nMES = max(1, round(nMNQ * beta * p.ptValueMNQ / p.ptValueMES));
            if useMicros
                riskUsed = nMNQ * stopPts * p.ptValueMNQ;
                txt = sprintf('%d MNQ / %d MES', nMNQ, nMES);
            else
                riskUsed = nNQ * stopPts * p.ptValueNQ;
                txt = sprintf('%d NQ / %d ES', nNQ, nES);
            end
            s = struct('nNQ', nNQ, 'nES', nES, 'nMNQ', nMNQ, 'nMES', nMES, ...
                'useMicros', useMicros, 'riskUsed', riskUsed, 'text', string(txt));
        end

        function d = defaults()
            d = struct( ...
                'entryZ', 2.0, 'confirmBars', 1, 'velBars', 3, ...
                'zVelMax', 1.0, 'rocMax', 0.15, ...
                'chopBand', 1.5, 'chopReversals', 3, 'chopWindow', 10, ...
                'consolBand', 1.0, 'consolBars', 4, ...
                'maxRiskUSD', 500, 'tpMode', "2R", 'stopZ', 2.0, ...
                'zExit', 0.0, 'zHardStop', 4.0, ...
                'armDist', 0.15, 'convBars', 5, ...
                'intertwineBand', 0.05, 'intertwineBars', 4, ...
                'gapDir', 'none', 'gapPolicy', 'block', ...
                'calmOnly', false, ...   % rule 2's momentum veto replaces the v2 calm-regime gate
                'ptValueNQ', 20, 'ptValueES', 50, ...
                'ptValueMNQ', 2, 'ptValueMES', 5);
        end
    end
end
