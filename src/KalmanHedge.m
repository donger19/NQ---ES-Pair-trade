classdef KalmanHedge < handle
    %KALMANHEDGE Online Kalman filter for the time-varying regression
    %   NQ_t = alpha_t + beta_t * ES_t + e_t
    %
    %   State:       x = [alpha; beta], random-walk transition
    %   Observation: NQ_t = [1, ES_t] * x + eps,  eps ~ N(0, R)
    %
    %   The residual returned for each bar is the innovation: the
    %   difference between actual NQ and the NQ predicted *before* seeing
    %   the bar - i.e. the part of NQ the regression cannot explain.

    properties
        Delta (1,1) double = 1e-5    % state noise ratio; larger = faster beta
        ZWindow (1,1) double = 60    % rolling window (bars) for residual z-score
        RLambda (1,1) double = 0.99  % EWMA forgetting factor for adaptive R
        P0Scale (1,1) double = 25    % inflate OLS covariance so the filter
                                     % adapts quickly if the warm-up window
                                     % was unrepresentative
    end

    properties (SetAccess = private)
        Alpha (1,1) double = 0
        Beta (1,1) double = 0
        P (2,2) double = eye(2)      % state covariance
        R (1,1) double = 1           % observation noise variance
        NumUpdates (1,1) double = 0
    end

    properties (Access = private)
        ResBuffer (:,1) double = zeros(0,1)
    end

    methods
        function warmStart(obj, nq, es)
            %WARMSTART Initialize state from OLS on a historical window.
            X = [ones(numel(es),1), es(:)];
            coef = X \ nq(:);
            res = nq(:) - X * coef;
            obj.Alpha = coef(1);
            obj.Beta = coef(2);
            obj.R = var(res);
            % OLS parameter covariance as the initial state uncertainty
            obj.P = obj.P0Scale * obj.R * inv(X' * X); %#ok<MINV>
            obj.ResBuffer = res(max(1, end-obj.ZWindow+1):end);
            obj.NumUpdates = 0;
        end

        function out = update(obj, nqClose, esClose)
            %UPDATE One Kalman predict+update step on a closed bar.
            Q = (obj.Delta / (1 - obj.Delta)) * eye(2);
            Ppred = obj.P + Q;                       % random-walk predict
            H = [1, esClose];
            x = [obj.Alpha; obj.Beta];
            yhat = H * x;                            % predicted NQ (prior)
            e = nqClose - yhat;                      % residual / innovation
            S = H * Ppred * H' + obj.R;              % innovation variance
            K = (Ppred * H') / S;
            x = x + K * e;
            obj.P = (eye(2) - K * H) * Ppred;
            obj.Alpha = x(1);
            obj.Beta = x(2);
            obj.R = obj.RLambda * obj.R + (1 - obj.RLambda) * e^2;
            obj.NumUpdates = obj.NumUpdates + 1;

            obj.ResBuffer = [obj.ResBuffer; e];
            if numel(obj.ResBuffer) > obj.ZWindow
                obj.ResBuffer = obj.ResBuffer(end-obj.ZWindow+1:end);
            end

            out = obj.packOutput(yhat, e, S);
        end

        function out = predictOnly(obj, nqClose, esClose)
            %PREDICTONLY Model outputs for a still-forming bar - no state
            %   change, so intra-bar noise never pollutes the filter.
            H = [1, esClose];
            yhat = H * [obj.Alpha; obj.Beta];
            e = nqClose - yhat;
            S = H * obj.P * H' + obj.R;
            out = obj.packOutput(yhat, e, S);
        end
    end

    methods (Access = private)
        function out = packOutput(obj, yhat, e, S)
            mu = mean(obj.ResBuffer);
            sd = std(obj.ResBuffer);
            if sd > 0
                z = (e - mu) / sd;
            else
                z = 0;
            end
            out = struct( ...
                'predictedNQ', yhat, ...
                'residual', e, ...
                'zScore', z, ...
                'innovStd', sqrt(S), ...
                'alpha', obj.Alpha, ...
                'beta', obj.Beta);
        end
    end
end
