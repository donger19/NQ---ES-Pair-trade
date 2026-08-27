classdef RegimeDetector < handle
    %REGIMEDETECTOR 2-state market regime detection on Kalman residuals.
    %   Primary: Markov-switching model (Econometrics Toolbox) fit on the
    %   residual series - states separate by variance into
    %   "Calm" (mean-reverting pair) vs "Volatile" (stressed/trending).
    %   Fallback: EWMA volatility-ratio thresholding if MS estimation
    %   fails to converge.

    properties
        Window (1,1) double = 400   % residuals kept for live filtering
        VolThreshold (1,1) double = 1.5  % fallback: EWMA vol / median vol
    end

    properties (SetAccess = private)
        Method (1,1) string = "none"      % "markov" | "fallback"
        EstMdl                             % estimated msVAR model
        VolatileState (1,1) double = 2     % index of high-variance state
        StateStd (1,2) double = [0 0]      % residual std per state
    end

    properties (Access = private)
        Buffer (:,1) double = zeros(0,1)
        MedianVol (1,1) double = 1
        EwmaVar (1,1) double = 1
    end

    methods
        function fit(obj, residuals)
            %FIT Estimate the regime model on historical residuals.
            residuals = residuals(:);
            residuals = residuals(~isnan(residuals));
            obj.Buffer = residuals(max(1, end-obj.Window+1):end);
            obj.MedianVol = median(abs(residuals)) * 1.4826; % robust sigma
            obj.EwmaVar = var(residuals);
            try
                mc = dtmc(NaN(2), 'StateNames', ["Calm" "Volatile"]);
                sub = [varm(1,0); varm(1,0)];
                Mdl = msVAR(mc, sub);
                s = var(residuals);
                mc0 = dtmc([0.95 0.05; 0.05 0.95], ...
                    'StateNames', ["Calm" "Volatile"]);
                sub0 = [varm('Constant', 0, 'Covariance', 0.5*s); ...
                        varm('Constant', 0, 'Covariance', 2.0*s)];
                Mdl0 = msVAR(mc0, sub0);
                obj.EstMdl = estimate(Mdl, Mdl0, residuals, ...
                    'IterationPlot', false);
                covs = arrayfun(@(m) m.Covariance, obj.EstMdl.Submodels);
                [~, obj.VolatileState] = max(covs);
                obj.StateStd = sqrt(covs(:))';
                obj.Method = "markov";
            catch ME
                warning('RegimeDetector:msFitFailed', ...
                    'Markov-switching fit failed (%s); using volatility fallback.', ...
                    ME.message);
                obj.Method = "fallback";
            end
        end

        function out = step(obj, residual)
            %STEP Update with one closed-bar residual; returns regime info.
            obj.Buffer = [obj.Buffer; residual];
            if numel(obj.Buffer) > obj.Window
                obj.Buffer = obj.Buffer(end-obj.Window+1:end);
            end
            out = obj.current();
        end

        function prm = paramsHMM(obj)
            %PARAMSHMM Frozen 2-state HMM parameters for the causal filter.
            %   Exported so pine/nq_es_pair.pine can run the identical
            %   forward recursion - Pine cannot estimate a Markov-switching
            %   model, but it can filter with fixed parameters.
            %   p11 = P(calm->calm), p22 = P(volatile->volatile).
            prm = struct('valid', false, 'p11', 0.95, 'p22', 0.95, ...
                'muCalm', 0, 'sdCalm', 1, 'muVol', 0, 'sdVol', 2);
            if obj.Method ~= "markov" || isempty(obj.EstMdl)
                return
            end
            P = obj.EstMdl.Switch.P;
            vol = obj.VolatileState;
            calm = 3 - vol;
            mus = arrayfun(@(m) m.Constant, obj.EstMdl.Submodels);
            sds = sqrt(arrayfun(@(m) m.Covariance, obj.EstMdl.Submodels));
            prm.valid = true;
            prm.p11 = P(calm, calm);
            prm.p22 = P(vol, vol);
            prm.muCalm = mus(calm);
            prm.sdCalm = sds(calm);
            prm.muVol = mus(vol);
            prm.sdVol = sds(vol);
        end

        function p = filterHMM(obj, residuals, prm)
            %FILTERHMM Causal 2-state Gaussian HMM forward filter.
            %   p(k) depends only on residuals(1:k) - no smoothing, so no
            %   lookahead. This is the recursion the Pine indicator mirrors.
            if nargin < 3 || isempty(prm)
                prm = obj.paramsHMM();
            end
            r = residuals(:);
            n = numel(r);
            p = nan(n, 1);
            % start from the stationary distribution of the chain
            denom = 2 - prm.p11 - prm.p22;
            if denom > 0
                aC = (1 - prm.p22) / denom;
                aV = (1 - prm.p11) / denom;
            else
                aC = 0.5; aV = 0.5;
            end
            for k = 1:n
                e = r(k);
                if isnan(e)
                    p(k) = aV;
                    continue
                end
                % predict
                pC = aC * prm.p11 + aV * (1 - prm.p22);
                pV = aC * (1 - prm.p11) + aV * prm.p22;
                % emission (the shared 1/sqrt(2*pi) cancels in normalisation)
                lC = exp(-0.5 * ((e - prm.muCalm) / prm.sdCalm)^2) / prm.sdCalm;
                lV = exp(-0.5 * ((e - prm.muVol) / prm.sdVol)^2) / prm.sdVol;
                wC = pC * lC;
                wV = pV * lV;
                s = wC + wV;
                if s > 0 && isfinite(s)
                    aC = wC / s;
                    aV = wV / s;
                else
                    aC = pC; aV = pV;   % degenerate: carry the prior forward
                end
                p(k) = aV;
            end
        end

        function p = filterEwma(obj, residuals)
            %FILTEREWMA Causal EWMA volatility-ratio pseudo-probability.
            %   Mirrors pine/nq_es_pair.pine:121-126 exactly: EWMA variance
            %   seeded with the first squared residual, robust sigma from a
            %   trailing 400-bar median, logistic squash around VolThreshold.
            r = residuals(:);
            n = numel(r);
            p = nan(n, 1);
            med = movmedian(abs(r), [obj.Window - 1, 0], 'omitnan') * 1.4826;
            v = NaN;
            for k = 1:n
                e = r(k);
                if isnan(e)
                    continue
                end
                if isnan(v)
                    v = e * e;                       % Pine: na(ewmaVar) ? e*e
                else
                    v = 0.94 * v + 0.06 * e * e;
                end
                ratio = sqrt(v) / max(med(k), 1e-10);
                p(k) = 1 / (1 + exp(-4 * (ratio - obj.VolThreshold)));
            end
        end

        function p = smoothAll(obj, residuals)
            %SMOOTHALL Volatile-state probability for a whole residual
            %   series in one pass (used for historical/backfill display).
            %
            %   WARNING - NOT CAUSAL. The markov branch runs a full-sample
            %   smoother, so p(k) depends on residuals after k. Display and
            %   diagnostics only. Never use it to drive a backtest: use
            %   filterHMM/filterEwma instead.
            residuals = residuals(:);
            if obj.Method == "markov"
                probs = smooth(obj.EstMdl, residuals);
                p = probs(:, obj.VolatileState);
                return
            end
            lambda = 0.94;
            n = numel(residuals);
            p = zeros(n, 1);
            v = var(residuals);
            for k = 1:n
                v = lambda * v + (1 - lambda) * residuals(k)^2;
                ratio = sqrt(v) / max(obj.MedianVol, eps);
                p(k) = 1 / (1 + exp(-4 * (ratio - obj.VolThreshold)));
            end
        end

        function out = current(obj)
            %CURRENT Regime probabilities from the current buffer.
            pVol = obj.probVolatile();
            if pVol >= 0.5
                label = "Volatile / stressed";
            else
                label = "Calm / mean-reverting";
            end
            out = struct('probVolatile', pVol, 'label', label, ...
                'method', obj.Method);
        end
    end

    methods (Access = private)
        function p = probVolatile(obj)
            if numel(obj.Buffer) < 20
                p = 0;
                return
            end
            if obj.Method == "markov"
                try
                    probs = smooth(obj.EstMdl, obj.Buffer);
                    p = probs(end, obj.VolatileState);
                    return
                catch
                    % fall through to volatility fallback
                end
            end
            lambda = 0.94;
            v = var(obj.Buffer);
            for k = max(1, numel(obj.Buffer)-60):numel(obj.Buffer)
                v = lambda * v + (1 - lambda) * obj.Buffer(k)^2;
            end
            ratio = sqrt(v) / max(obj.MedianVol, eps);
            % squash the vol ratio into a pseudo-probability around threshold
            p = 1 / (1 + exp(-4 * (ratio - obj.VolThreshold)));
        end
    end
end
