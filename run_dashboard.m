function app = run_dashboard()
%RUN_DASHBOARD Launch the live NQ-ES pair model dashboard.
%   Loads config.json, verifies the Python websocket dependency, and
%   starts the dashboard. Close the window to stop the feed cleanly.

root = fileparts(mfilename('fullpath'));
addpath(fullfile(root, 'src'), fullfile(root, 'app'));

% config
cfgFile = fullfile(root, 'config.json');
if isfile(cfgFile)
    cfg = jsondecode(fileread(cfgFile));
else
    cfg = struct();
end

% ensure python dependency
try
    py.importlib.import_module('websocket');
catch
    fprintf('Installing python dependency websocket-client...\n');
    pe = pyenv;
    [status, out] = system(sprintf('"%s" -m pip install websocket-client', ...
        pe.Executable));
    if status ~= 0
        error('pip install failed:\n%s', out);
    end
end

app = PairDashboard(cfg);
end
