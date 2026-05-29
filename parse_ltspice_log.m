function [p_dbm, v_dc] = parse_ltspice_log(filePath)
% PARSE_LTSPICE_LOG  Two-pass text-scanning parser for LTspice .log files.
%
% Extracts the swept power vector and corresponding averaged DC output
% voltages from an LTspice .step parametric sweep log.
%
% PASS 1 — Dynamic Axis Scan:
%   Scans every line for the pattern ".step p_dbm=<value>" and assembles
%   the available input power vector. This is fully dynamic — does not
%   hardcode the sweep range, step count, or parameter name format.
%
% PASS 2 — Measurement Anchor Detection:
%   Searches for a line containing "Measurement:" (any label). Skips the
%   column header row ("step  AVG(...)  FROM  TO"), then extracts the
%   numeric voltage from Column 2 for each data row until a non-numeric
%   or empty line terminates the table.
%
% INPUTS:
%   filePath - Full path to the LTspice .log file (ASCII text)
%
% OUTPUTS:
%   p_dbm - Column vector of input power levels (dBm), one per .step
%   v_dc  - Column vector of averaged DC output voltages (V)
%
% ERRORS:
%   Throws an error if:
%     - No .step lines are found
%     - No measurement table is found
%     - The number of .step lines does not match the number of voltage rows
%
% EXAMPLE:
%   [p_dbm, v_dc] = parse_ltspice_log('HSMS-2850.log');
%   R_load = 1000;
%   eta = (v_dc.^2 ./ R_load) ./ (10.^((p_dbm - 30) ./ 10));

    % Read entire file and strip UTF-16 null bytes
    raw_text = fileread(filePath);
    raw_text = strrep(raw_text, char(0), ''); % Strip UTF-16 null bytes
    lines = splitlines(raw_text);

    % ---- Pass 1: Scan for .step p_dbm=<value> lines ----
    p_dbm = [];
    for i = 1:length(lines)
        tokens = regexp(lines{i}, 'p_dbm\s*=\s*([-+\d.]+)', 'tokens', 'ignorecase');
        if ~isempty(tokens)
            p_dbm(end+1) = str2double(tokens{1}{1}); %#ok<AGROW>
        end
    end

    if isempty(p_dbm)
        error('parse_ltspice_log:NoStepLines', ...
            'No ".step p_dbm=" lines found in %s', filePath);
    end

    % ---- Pass 2: Anchor on "Measurement:" and extract V_dc ----
    v_dc = [];
    anchor_found = false;
    skip_next = false;   % Flag to skip the column header line

    for i = 1:length(lines)
        line = strtrim(lines{i});

        if ~anchor_found
            % Search for the measurement anchor (any label after "Measurement:")
            if contains(line, 'Measurement:', 'IgnoreCase', true)
                anchor_found = true;
                skip_next = true;  % Next line is the column header
            end
            continue;
        end

        % Skip the column header row ("step  AVG(v(dc_out))  FROM  TO")
        if skip_next
            skip_next = false;
            continue;
        end

        % Parse data rows: "  <step_idx>  <voltage>  <from>  <to>"
        tokens = regexp(line, '^\d+\s+([\d.eE+-]+)', 'tokens');
        if ~isempty(tokens)
            v_dc(end+1) = str2double(tokens{1}{1}); %#ok<AGROW>
        else
            % Non-numeric or empty line → end of measurement table
            break;
        end
    end

    if isempty(v_dc)
        error('parse_ltspice_log:NoMeasurementData', ...
            'No measurement data found after "Measurement:" anchor in %s', filePath);
    end

    % ---- Sanity Check: Dimension Agreement ----
    if length(p_dbm) ~= length(v_dc)
        error('parse_ltspice_log:DimensionMismatch', ...
            'Parsed %d .step lines but %d voltage rows in %s', ...
            length(p_dbm), length(v_dc), filePath);
    end

    % Return as column vectors
    p_dbm = p_dbm(:);
    v_dc  = v_dc(:);
end
