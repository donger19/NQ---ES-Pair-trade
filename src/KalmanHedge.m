classdef KalmanHedge < handle
    %KALMANHEDGE Online Kalman filter for the time-varying regression
    %   log(NQ_t) = alpha_t + beta_t * (log(ES_t) - log(EsRef)) + e_t
    %
    %   State:       x = [alpha; beta], random-walk transition
    %   Observation: log-NQ = [1, xES] * x + eps,  eps ~ N(0, R)
    %
    %   WHY LOG-LOG AND CENTERED. The obvious price-space form
    %   NQ = alpha + beta*ES is unidentified on index data: the design
    %   matrix [1, ES] has condition number ~4e5 (ES sits near 7600 with a
    %   standard deviation of ~130), so alpha and beta are collinear and the
    %   likelihood is a flat valley. The filter never leaves wherever it was
    %   initialized, and two implementations seeded differently disagree on
    %   beta forever - measured 3.81 vs 6.02 after 41,000 bars, differing on
    %   4% of |z|>=2 entry decisions. Centering the log regressor drops the
    %   condition number to ~58, which makes the model identified: opposite
    %   initializations converge (beta 1.6441 vs 1.6444, z correlation
    %   0.9988). That convergence is what lets the Pine indicator and this
    %   class be the same model rather than two similar ones.
    %
    %   Everything downstream stays in NQ POINTS. The residual returned is
    %   the innovation in points (actual NQ minus the NQ predicted before
    %   seeing the bar), and `beta` in the output struct is the PRICE-SPACE
    %   hedge ratio dNQ/dES = beta_log * predictedNQ / ES, which is what the
    %   ES leg and the pair P&L are sized on.

    properties
        Delta (1,1) double = 1e-8    % state noise ratio; larger = faster beta
        ZWindow (1,1) double = 60    % rolling window (bars) for residual z-score
        RLambda (1,1) double = 0.99  % EWMA forgetting factor for adaptive R
        P0Scale (1,1) double = 25    % inflate OLS covariance (warmStart only)
        EsRef (1,1) double = 7550    % ES centering anchor; must match the
                                     % Pine input. Only affects conditioning:
                                     % alpha absorbs any anchor error.
    end

    properties (SetAccess = private)
        AlphaLog (1,1) double = 0    % log-space intercept (the filter state)
        BetaLog (1,1) double = 1     % log-space slope = return elasticity
        Alpha (1,1) double = 0       % price-space intercept, for display
        Beta (1,1) double = 0        % price-space hedge ratio dNQ/dES
        P (2,2) double = 1e-2*eye(2) % state covariance
        R (1,1) double = 1e-6        % observation noise variance (log units)
        NumUpdates (1,1) double = 0
    end

    properties (Access = private)
        ResBuffer (:,1) double = zeros(0,1)   % innovations in NQ POINTS
        Seeded (1,1) logical = false
    end

    methods
        function seed(obj, nq0)
            %SEED Naive initialization from the first bar.
            %   Deliberately simple so pine/nq_es_pair.pine can reproduce it
            %   exactly: the reparameterized filter is identified, so this
            %   converges to the same place an OLS warm start would.
            obj.AlphaLog = log(nq0);
            obj.BetaLog = 1.0;
            obj.P = 1e-2 * eye(2);
            obj.R = 1e-6;
            obj.ResBuffer = zeros(0,1);
            obj.NumUpdates = 0;
            obj.Seeded = true;
        end

        function warmStart(obj, nq, es)
            %WARMSTART Initialize state from log-space OLS on a window.
            %   Diagnostic / faster-converging alternative to seed(). Not
            %   used by computeFeatures: the backtest mirrors Pine's naive
            %   seed so the two run bit-comparable paths.
            x = log(es(:)) - log(obj.EsRef);
            y = log(nq(:));
            X = [ones(numel(x),1), x];
            coef = X \ y;
            res = y - X * coef;
            obj.AlphaLog = coef(1);
            obj.BetaLog = coef(2);
            obj.R = var(res);
            obj.P = obj.P0Scale * obj.R * inv(X' * X); %#ok<MINV>
            obj.ResBuffer = zeros(0,1);
            obj.NumUpdates = 0;
            obj.Seeded = true;
        end

        function out = update(obj, nqClose, esClose)
            %UPDATE One Kalman predict+update step on a closed bar.
            if ~obj.Seeded
                obj.seed(nqClose);
            end
            xES = log(esClose) - log(obj.EsRef);
            H = [1, xES];
            Q = (obj.Delta / (1 - obj.Delta)) * eye(2);
            Ppred = obj.P + Q;                       % random-walk predict
            state = [obj.AlphaLog; obj.BetaLog];
            yhat = H * state;                        % predicted log-NQ (prior)
            eLog = log(nqClose) - yhat;              % innovation, log units
            S = H * Ppred * H' + obj.R;
            K = (Ppred * H') / S;
            state = state + K * eLog;
            obj.P = (eye(2) - K * H) * Ppred;
            obj.AlphaLog = state(1);
            obj.BetaLog = state(2);
            obj.R = obj.RLambda * obj.R + (1 - obj.RLambda) * eLog^2;
            obj.NumUpdates = obj.NumUpdates + 1;

            [predNQ, e] = obj.toPoints(yhat, nqClose);
            obj.ResBuffer = [obj.ResBuffer; e];
            if numel(obj.ResBuffer) > obj.ZWindow
                obj.ResBuffer = obj.ResBuffer(end-obj.ZWindow+1:end);
            end
            obj.refreshPriceSpace(predNQ, esClose);
            out = obj.packOutput(predNQ, e, S);
        end

        function out = predictOnly(obj, nqClose, esClose)
            %PREDICTONLY Model outputs for a still-forming bar - no state
            %   change, so intra-bar noise never pollutes the filter.
            if ~obj.Seeded
                obj.seed(nqClose);
            end
            xES = log(esClose) - log(obj.EsRef);
            H = [1, xES];
            yhat = H * [obj.AlphaLog; obj.BetaLog];
            S = H * obj.P * H' + obj.R;
            [predNQ, e] = obj.toPoints(yhat, nqClose);
            obj.refreshPriceSpace(predNQ, esClose);
            out = obj.packOutput(predNQ, e, S);
        end
    end

    methods (Access = private)
        function [predNQ, e] = toPoints(~, yhatLog, nqClose)
            %TOPOINTS Fitted level and innovation, both in NQ points.
            predNQ = exp(yhatLog);
            e = nqClose - predNQ;
        end

        function refreshPriceSpace(obj, predNQ, esClose)
            %REFRESHPRICESPACE Local affine view of the log relation.
            %   Beta is the slope of the fitted curve at this bar,
            %   dNQ/dES = beta_log * NQ_fit / ES, and Alpha is chosen so
            %   Alpha + Beta*ES reproduces the fitted level exactly. This
            %   keeps SignalEngine.freezeFair, the ES hedge leg and the
            %   dashboard working in price space unchanged.
            obj.Beta = obj.BetaLog * predNQ / esClose;
            obj.Alpha = predNQ - obj.Beta * esClose;
        end

        function out = packOutput(obj, predNQ, e, S)
            mu = mean(obj.ResBuffer);
            sd = std(obj.ResBuffer);
            if numel(obj.ResBuffer) < obj.ZWindow
                % Window not full: an under-filled std is not comparable to
                % the steady-state one. NaN makes SignalEngine skip the bar
                % rather than size a position off a bad number.
                sd = NaN;
            end
            if sd > 0
                z = (e - mu) / sd;
            else
                z = NaN;
            end
            % resMu/resSd are the exact window statistics behind zScore.
            % Callers must reuse these rather than recomputing the rolling
            % std themselves - a second, differently-seeded estimate is how
            % z and resSd drifted apart previously.
            out = struct( ...
                'predictedNQ', predNQ, ...
                'residual', e, ...
                'zScore', z, ...
                'resMu', mu, ...
                'resSd', sd, ...
                'innovStd', sqrt(S), ...
                'alpha', obj.Alpha, ...
                'beta', obj.Beta, ...
                'alphaLog', obj.AlphaLog, ...
                'betaLog', obj.BetaLog);
        end
    end
end
