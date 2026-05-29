classdef App_ideal < matlab.apps.AppBase

    % Properties that correspond to app components
    properties (Access = public)
        UIFigure                      matlab.ui.Figure
        UIAxes                        matlab.ui.control.UIAxes

        % --- Input Controls: Frequency ---
        FrequencyEditField            matlab.ui.control.NumericEditField
        FrequencyLabel                matlab.ui.control.Label
        FrequencyMHzSlider            matlab.ui.control.Slider

        % --- Input Controls: TX Antenna (Diameter) ---
        TxAntennaEditField            matlab.ui.control.NumericEditField
        TxAntennaLabel                matlab.ui.control.Label
        TxAntennaSlider               matlab.ui.control.Slider

        % --- Input Controls: RX Antenna (Diameter) ---
        RxAntennaEditField            matlab.ui.control.NumericEditField
        RxAntennaLabel                matlab.ui.control.Label
        RxAntennaSlider               matlab.ui.control.Slider

        % --- Input Controls: Max Distance ---
        MaxDistanceEditField          matlab.ui.control.NumericEditField
        MaxDistanceLabel              matlab.ui.control.Label

        % --- Realistic Mode Toggle ---
        RealisticToggleLabel          matlab.ui.control.Label
        RealisticToggle               matlab.ui.control.Switch

        % --- Realistic Constraints Panel ---
        RealisticPanel                matlab.ui.container.Panel
        PathLossExpLabel              matlab.ui.control.Label
        PathLossExpEditField          matlab.ui.control.NumericEditField
        AutoNCheckbox                 matlab.ui.control.CheckBox
        PolarizationLabel             matlab.ui.control.Label
        PolarizationDropDown          matlab.ui.control.DropDown
        LhwLabel                      matlab.ui.control.Label
        LhwEditField                  matlab.ui.control.NumericEditField
        AutoLhwCheckbox               matlab.ui.control.CheckBox
        S11TxLabel                    matlab.ui.control.Label
        S11TxEditField                matlab.ui.control.NumericEditField
        S11RxLabel                    matlab.ui.control.Label
        S11RxEditField                matlab.ui.control.NumericEditField
        AutoRectennaCheckbox          matlab.ui.control.CheckBox
        LoadRectennaButton            matlab.ui.control.Button
        RectennaStatusLabel           matlab.ui.control.Label
        RloadLabel                    matlab.ui.control.Label
        RloadEditField                matlab.ui.control.NumericEditField

        % --- Inductive Coil Panel (Phase 3) ---
        CoilPanel                     matlab.ui.container.Panel
        TxCoilDiamLabel               matlab.ui.control.Label
        TxCoilDiamEditField           matlab.ui.control.NumericEditField
        TxCoilDiamSlider              matlab.ui.control.Slider
        RxCoilDiamLabel               matlab.ui.control.Label
        RxCoilDiamEditField           matlab.ui.control.NumericEditField
        RxCoilDiamSlider              matlab.ui.control.Slider
        TxTurnsLabel                  matlab.ui.control.Label
        TxTurnsEditField              matlab.ui.control.NumericEditField
        RxTurnsLabel                  matlab.ui.control.Label
        RxTurnsEditField              matlab.ui.control.NumericEditField
        WireGaugeLabel                matlab.ui.control.Label
        WireGaugeDropDown             matlab.ui.control.DropDown
        CoilInfoLabel1                matlab.ui.control.Label
        CoilInfoLabel2                matlab.ui.control.Label
        CoilResonanceNote             matlab.ui.control.Label
        DistElemWarning               matlab.ui.control.Label

        % --- Physics Mode Toggle (Hybrid Zone) ---
        PhysicsModeLabel              matlab.ui.control.Label
        PhysicsModeDropDown           matlab.ui.control.DropDown

        % --- Readout Panel & Fields ---
        ReadoutPanel                  matlab.ui.container.Panel
        NearFieldLabel                matlab.ui.control.Label
        NearFieldValue                matlab.ui.control.Label
        TxGainLabel                   matlab.ui.control.Label
        TxGainValue                   matlab.ui.control.Label
        RxGainLabel                   matlab.ui.control.Label
        RxGainValue                   matlab.ui.control.Label
        QueryDistanceLabel            matlab.ui.control.Label
        QueryDistanceEditField        matlab.ui.control.NumericEditField
        PrxLabel                      matlab.ui.control.Label
        PrxValue                      matlab.ui.control.Label
        EffLabel                      matlab.ui.control.Label
        EffValue                      matlab.ui.control.Label

        % --- Action Buttons ---
        LockGraphforComparisonButton  matlab.ui.control.Button
        ClearGraphButton              matlab.ui.control.Button
    end


    properties (Access = private)
        SavedCurves = {}           % Cell array of saved comparison curve structs
        LastResults = []           % Ideal far-field results cache
        LastRealisticResults = []  % Realistic far-field results cache
        LastNearfieldResults = []  % Near-field results cache
        RectennaCurve = []         % Loaded [P_rx_dBm, eff] matrix from CSV/Log
        ParsedLogData = []         % Struct: {p_dbm, v_dc, filename} for live R_load recompute
        CurrentFreqZone = 'farfield'  % 'farfield', 'hybrid', 'nearfield'
    end

    % Core logic: heuristics, frequency zone, plot update, numerical readout
    methods (Access = private)

        function updateHeuristics(app)
            % Called on frequency change and at startup.
            % Updates Auto-checked fields with heuristic values.
            freq_Hz = app.FrequencyEditField.Value * 1e6;
            h = wpt_heuristics(freq_Hz);

            % Path loss exponent
            if app.AutoNCheckbox.Value
                app.PathLossExpEditField.Value = round(h.n_path, 2);
            end

            % Hardware / insertion loss
            if app.AutoLhwCheckbox.Value
                app.LhwEditField.Value = round(h.L_hardware_dB, 1);
            end

            % Rectenna status display (when auto and no CSV loaded)
            if app.AutoRectennaCheckbox.Value
                app.RectennaStatusLabel.Text = sprintf( ...
                    'Auto: peak=%.1f%% @ %.0f MHz', ...
                    h.eta_peak * 100, freq_Hz / 1e6);
                app.RectennaStatusLabel.FontColor = [0 0.35 0.65];
            end

            % Update frequency zone with hysteresis
            updateFreqZone(app);
        end

        function updateFreqZone(app)
            % True hysteresis: asymmetric thresholds prevent panel flicker.
            % Thresholds (in Hz):
            %   farfield -> hybrid:  freq drops below 30 MHz
            %   hybrid -> farfield:  freq rises above 70 MHz
            %   hybrid -> nearfield: freq drops below 800 kHz
            %   nearfield -> hybrid: freq rises above 1.5 MHz
            freq_Hz = app.FrequencyEditField.Value * 1e6;
            old_zone = app.CurrentFreqZone;
            new_zone = old_zone;

            switch old_zone
                case 'farfield'
                    if freq_Hz < 30e6
                        new_zone = 'hybrid';
                    end
                case 'hybrid'
                    if freq_Hz > 70e6
                        new_zone = 'farfield';
                    elseif freq_Hz < 800e3
                        new_zone = 'nearfield';
                    end
                case 'nearfield'
                    if freq_Hz > 1.5e6
                        new_zone = 'hybrid';
                    end
            end

            if ~strcmp(old_zone, new_zone)
                app.CurrentFreqZone = new_zone;
                applyFreqZoneVisibility(app);
            end
        end

        function applyFreqZoneVisibility(app)
            switch app.CurrentFreqZone
                case 'farfield'
                    setAntennaControlsVisible(app, true);
                    app.CoilPanel.Visible = 'off';
                    app.PhysicsModeLabel.Visible = 'off';
                    app.PhysicsModeDropDown.Visible = 'off';
                    % Show realistic toggle (far-field feature)
                    app.RealisticToggleLabel.Visible = 'on';
                    app.RealisticToggle.Visible = 'on';
                case 'hybrid'
                    setAntennaControlsVisible(app, true);
                    app.CoilPanel.Visible = 'on';
                    app.PhysicsModeLabel.Visible = 'on';
                    app.PhysicsModeDropDown.Visible = 'on';
                    app.RealisticToggleLabel.Visible = 'on';
                    app.RealisticToggle.Visible = 'on';
                case 'nearfield'
                    setAntennaControlsVisible(app, false);
                    app.CoilPanel.Visible = 'on';
                    app.PhysicsModeLabel.Visible = 'off';
                    app.PhysicsModeDropDown.Visible = 'off';
                    % Hide realistic toggle (far-field losses don't apply)
                    app.RealisticToggleLabel.Visible = 'off';
                    app.RealisticToggle.Visible = 'off';
                    if strcmp(app.RealisticToggle.Value, 'Realistic')
                        app.RealisticPanel.Visible = 'off';
                    end
            end
        end

        function setAntennaControlsVisible(app, visible)
            vis = 'off';
            if visible; vis = 'on'; end
            app.TxAntennaEditField.Visible = vis;
            app.TxAntennaLabel.Visible = vis;
            app.TxAntennaSlider.Visible = vis;
            app.RxAntennaEditField.Visible = vis;
            app.RxAntennaLabel.Visible = vis;
            app.RxAntennaSlider.Visible = vis;
        end

        function updatePlot(app)
            % ============================================================
            %  UNIFIED PLOT ENGINE (Phase 3)
            %  Handles far-field, near-field, and combined crossover.
            % ============================================================

            % 1. Common parameters
            freq_Hz = app.FrequencyEditField.Value * 1e6;
            max_dist = app.MaxDistanceEditField.Value;
            d_vec = linspace(0.005, max_dist, 500);
            P_tx_dBm = 20;

            % 2. Determine which models to run
            run_farfield = false;
            run_nearfield = false;
            switch app.CurrentFreqZone
                case 'farfield'
                    run_farfield = true;
                case 'hybrid'
                    mode = app.PhysicsModeDropDown.Value;
                    if strcmp(mode, 'Both Curves') || strcmp(mode, 'Far-Field Only')
                        run_farfield = true;
                    end
                    if strcmp(mode, 'Both Curves') || strcmp(mode, 'Near-Field Only')
                        run_nearfield = true;
                    end
                case 'nearfield'
                    run_nearfield = true;
            end

            % 3. Compute far-field results
            results_ideal = [];
            results_real = [];
            if run_farfield
                params.freq_Hz      = freq_Hz;
                params.D_tx_m       = app.TxAntennaEditField.Value / 100;
                params.D_rx_m       = app.RxAntennaEditField.Value / 100;
                params.P_tx_dBm     = P_tx_dBm;
                params.n_path       = 2;
                params.eff_rectenna = 0.60;
                params.eta_ap       = 0.60;
                params.d_vec        = d_vec;

                results_ideal = wpt_farfield_model(params);

                % Realistic overlay
                realistic_on = strcmp(app.RealisticToggle.Value, 'Realistic');
                if realistic_on
                    params_real = params;
                    params_real.n_path              = app.PathLossExpEditField.Value;
                    params_real.polarization_factor  = app.PolarizationDropDown.Value;
                    params_real.S11_tx_dB           = app.S11TxEditField.Value;
                    params_real.S11_rx_dB           = app.S11RxEditField.Value;
                    params_real.L_hardware_dB       = app.LhwEditField.Value;
                    if ~isempty(app.RectennaCurve)
                        params_real.rectenna_curve = app.RectennaCurve;
                    elseif app.AutoRectennaCheckbox.Value
                        params_real.use_heuristic_rectenna = true;
                    end
                    results_real = wpt_farfield_model(params_real);
                end
            end
            app.LastResults = results_ideal;
            app.LastRealisticResults = results_real;

            % 4. Compute near-field results
            results_nf = [];
            if run_nearfield
                nf_params.freq_Hz   = freq_Hz;
                % UI shows DIAMETER in cm — convert to RADIUS in m
                nf_params.r_tx_m    = (app.TxCoilDiamEditField.Value / 2) / 100;
                nf_params.r_rx_m    = (app.RxCoilDiamEditField.Value / 2) / 100;
                nf_params.N_tx      = round(app.TxTurnsEditField.Value);
                nf_params.N_rx      = round(app.RxTurnsEditField.Value);
                nf_params.AWG_tx    = app.WireGaugeDropDown.Value;
                nf_params.AWG_rx    = app.WireGaugeDropDown.Value;
                nf_params.d_vec     = d_vec;
                nf_params.P_tx_dBm  = P_tx_dBm;

                results_nf = wpt_nearfield_model(nf_params);

                % Update coil info labels
                app.CoilInfoLabel1.Text = sprintf('L_tx = %.2f uH  |  L_rx = %.2f uH', ...
                    results_nf.L1 * 1e6, results_nf.L2 * 1e6);
                app.CoilInfoLabel2.Text = sprintf('Q_tx = %.0f  |  Q_rx = %.0f', ...
                    results_nf.Q1, results_nf.Q2);

                % Distributed element warning
                if results_nf.wire_exceeds_lam10
                    app.DistElemWarning.Text = sprintf( ...
                        'Warning: Coil length (%.2f m) exceeds %s/10. Distributed element effects dominate.', ...
                        results_nf.max_wire_length_m, char(955));
                    app.DistElemWarning.FontColor = [0.8 0 0];
                    app.DistElemWarning.Visible = 'on';
                else
                    app.DistElemWarning.Visible = 'off';
                end
            else
                app.DistElemWarning.Visible = 'off';
            end
            app.LastNearfieldResults = results_nf;

            % ============================================================
            % 5. CLEAR AND REBUILD THE PLOT
            % ============================================================
            cla(app.UIAxes, 'reset');
            hold(app.UIAxes, 'on');

            colors = get(groot, 'defaultAxesColorOrder');
            n_colors = size(colors, 1);
            curve_idx = 0;

            % 6. Re-plot saved comparison curves
            for i = 1:length(app.SavedCurves)
                curve_idx = curve_idx + 1;
                c = colors(mod(curve_idx - 1, n_colors) + 1, :);
                sc = app.SavedCurves{i};

                % Ideal far-field (solid, thin)
                if ~isempty(sc.eff_ideal)
                    plot(app.UIAxes, sc.d_vec, sc.eff_ideal, '-', ...
                        'LineWidth', 1.5, 'Color', c, ...
                        'DisplayName', sc.label);
                end
                % Realistic far-field (dashed, thin)
                if sc.has_realistic
                    plot(app.UIAxes, sc.d_vec, sc.eff_realistic, '--', ...
                        'LineWidth', 1.5, 'Color', c, ...
                        'DisplayName', [sc.label ' (real.)']);
                end
                % Near-field (dot-dash, thin)
                if sc.has_nearfield
                    plot(app.UIAxes, sc.d_vec, sc.eff_nearfield, '-.', ...
                        'LineWidth', 1.5, 'Color', c, ...
                        'DisplayName', [sc.label ' (induct.)']);
                end
            end

            % 7. Plot the active far-field curve
            if run_farfield && ~isempty(results_ideal)
                curve_idx = curve_idx + 1;
                active_c = colors(mod(curve_idx - 1, n_colors) + 1, :);
                active_label = sprintf('%.1f MHz | TX:%dcm RX:%dcm', ...
                    results_ideal.freq_MHz, round(results_ideal.D_tx_cm), ...
                    round(results_ideal.D_rx_cm));

                % Active ideal (solid, thick)
                plot(app.UIAxes, d_vec, results_ideal.eff_system_pct, '-', ...
                    'LineWidth', 2.5, 'Color', active_c, ...
                    'DisplayName', [active_label ' (FF)']);

                % Active realistic (dashed, thick)
                if ~isempty(results_real)
                    plot(app.UIAxes, d_vec, results_real.eff_system_pct, '--', ...
                        'LineWidth', 2.5, 'Color', active_c, ...
                        'DisplayName', [active_label ' (FF real.)']);
                end
            end

            % 8. Plot the active near-field curve
            nf_color = [0.15 0.55 0.15];  % Forest green — always distinct
            if run_nearfield && ~isempty(results_nf) && ~results_nf.wire_exceeds_lam10
                nf_label = sprintf('%.2f MHz | D:%dcm N:%d (Inductive)', ...
                    freq_Hz / 1e6, ...
                    round(app.TxCoilDiamEditField.Value), ...
                    round(app.TxTurnsEditField.Value));
                plot(app.UIAxes, d_vec, results_nf.eta_inductive_pct, '-.', ...
                    'LineWidth', 2.5, 'Color', nf_color, ...
                    'DisplayName', nf_label);
            end


            % 10. Y-axis limits (encompass ALL visible curves)
            all_valid = [];
            if ~isempty(results_ideal)
                all_valid = [all_valid, results_ideal.eff_system_pct(~isnan(results_ideal.eff_system_pct))];
            end
            if ~isempty(results_real)
                all_valid = [all_valid, results_real.eff_system_pct(~isnan(results_real.eff_system_pct))];
            end
            if ~isempty(results_nf)
                all_valid = [all_valid, results_nf.eta_inductive_pct(~isnan(results_nf.eta_inductive_pct))];
            end
            for i = 1:length(app.SavedCurves)
                sc = app.SavedCurves{i};
                if ~isempty(sc.eff_ideal)
                    all_valid = [all_valid, sc.eff_ideal(~isnan(sc.eff_ideal))]; %#ok<AGROW>
                end
                if sc.has_realistic
                    all_valid = [all_valid, sc.eff_realistic(~isnan(sc.eff_realistic))]; %#ok<AGROW>
                end
                if sc.has_nearfield
                    all_valid = [all_valid, sc.eff_nearfield(~isnan(sc.eff_nearfield))]; %#ok<AGROW>
                end
            end
            if isempty(all_valid)
                ylim(app.UIAxes, [0 1]);
            else
                ylim(app.UIAxes, [0, max(max(all_valid) * 1.1, 0.1)]);
            end

            % 11. Fresnel / Transition Zone Shading
            if ~isempty(results_ideal)
                d0 = results_ideal.near_field_boundary_m;
                if d0 > d_vec(1) && d0 < d_vec(end)
                    yl = ylim(app.UIAxes);
                    h_patch = patch(app.UIAxes, ...
                        [d_vec(1) d0 d0 d_vec(1)], ...
                        [yl(1) yl(1) yl(2) yl(2)], ...
                        [0.9 0.85 0.75], ...
                        'FaceAlpha', 0.15, ...
                        'EdgeColor', 'none', ...
                        'HandleVisibility', 'off');
                    % Push patch BEHIND all curves so inductive line is visible
                    uistack(h_patch, 'bottom');

                    % Text annotation — robust placement at 92% of axis height
                    text_y = yl(1) + 0.92 * (yl(2) - yl(1));
                    text(app.UIAxes, (d_vec(1) + d0) / 2, text_y, ...
                        {'Transition Region'; 'Friis model invalid'}, ...
                        'FontSize', 8, 'Color', [0.5 0.3 0.1], ...
                        'HorizontalAlignment', 'center', ...
                        'FontAngle', 'italic');
                end
            end

            % 12. Crossover Detection & Annotation
            if ~isempty(results_ideal) && ~isempty(results_nf)
                eff_ff = results_ideal.eff_system_pct;
                eff_nf = results_nf.eta_inductive_pct;
                both_valid = ~isnan(eff_ff) & ~isnan(eff_nf);

                if sum(both_valid) >= 2
                    delta = eff_ff(both_valid) - eff_nf(both_valid);
                    d_valid = d_vec(both_valid);

                    % Guard: treat near-zero as exactly zero (edge case)
                    delta(abs(delta) < 1e-10) = 0;
                    sign_delta = sign(delta);
                    sign_changes = find(diff(sign_delta) ~= 0);

                    % Deduplicate adjacent sign changes (same crossover)
                    if length(sign_changes) > 1
                        keep = true(size(sign_changes));
                        for j = 2:length(sign_changes)
                            if sign_changes(j) - sign_changes(j-1) <= 1
                                keep(j) = false;
                            end
                        end
                        sign_changes = sign_changes(keep);
                    end

                    for ci = 1:length(sign_changes)
                        idx = sign_changes(ci);
                        if idx < length(d_valid)
                            d_cross = interp1(delta(idx:idx+1), d_valid(idx:idx+1), 0);
                            eff_cross = interp1(d_valid, eff_nf(both_valid), d_cross);

                            xline(app.UIAxes, d_cross, '--k', 'LineWidth', 1.0, ...
                                'HandleVisibility', 'off');

                            if ci == 1
                                % First crossover: bold annotation
                                text(app.UIAxes, d_cross, eff_cross, ...
                                    sprintf('  Crossover: %.3f m', d_cross), ...
                                    'FontSize', 9, 'FontWeight', 'bold', ...
                                    'Color', [0.1 0.1 0.1], ...
                                    'VerticalAlignment', 'bottom');
                            else
                                % Subsequent: lighter, smaller
                                text(app.UIAxes, d_cross, eff_cross, ...
                                    sprintf('  Crossover: %.3f m', d_cross), ...
                                    'FontSize', 7, 'FontWeight', 'normal', ...
                                    'Color', [0.5 0.5 0.5], ...
                                    'VerticalAlignment', 'bottom');
                            end
                        end
                    end
                end
            end

            % 13. Axes formatting, legend, title
            legend(app.UIAxes, 'show', 'Location', 'northeast');
            app.UIAxes.XLabel.String = 'Distance (m)';
            app.UIAxes.YLabel.String = 'System Efficiency (%)';
            grid(app.UIAxes, 'on');

            % Dynamic title based on frequency zone
            em = char(8212);  % em-dash
            switch app.CurrentFreqZone
                case 'farfield'
                    if ~isempty(results_ideal)
                        if all(results_ideal.invalid_indices)
                            app.UIAxes.Title.String = sprintf( ...
                                'Warning: Far-field begins at %.2f m (beyond plot range)', ...
                                results_ideal.near_field_boundary_m);
                            app.UIAxes.Title.Color = [0.8 0 0];
                        else
                            app.UIAxes.Title.String = sprintf( ...
                                'Far-Field WPT Link Budget  |  Valid beyond %.2f m', ...
                                results_ideal.near_field_boundary_m);
                            app.UIAxes.Title.Color = [0.1 0.1 0.1];
                        end
                    else
                        app.UIAxes.Title.String = 'WPT Link Budget';
                        app.UIAxes.Title.Color = [0.1 0.1 0.1];
                    end
                case 'hybrid'
                    app.UIAxes.Title.String = ['WPT Link Budget ' em ' Radiative & Inductive Crossover'];
                    app.UIAxes.Title.Color = [0.1 0.1 0.1];
                case 'nearfield'
                    app.UIAxes.Title.String = ['WPT Link Budget ' em ' Inductive Coupling'];
                    app.UIAxes.Title.Color = [0.1 0.1 0.1];
            end

            % 14. Force auto-scale so near-field curves are never clipped
            ylim(app.UIAxes, 'auto');
            xlim(app.UIAxes, [0, max_dist]);

            % 15. Update Numerical Readouts
            updateReadouts(app, results_ideal, results_real, results_nf);
        end

        function updateReadouts(app, results_ideal, results_real, results_nf)
            % --- Static readouts (from far-field: gains, NF boundary) ---
            if ~isempty(results_ideal)
                app.NearFieldValue.Text = sprintf('%.3f m', results_ideal.near_field_boundary_m);
                app.TxGainValue.Text    = sprintf('%+.2f dBi', results_ideal.G_tx_dBi);
                app.RxGainValue.Text    = sprintf('%+.2f dBi', results_ideal.G_rx_dBi);
                app.NearFieldLabel.Visible = 'on';  app.NearFieldValue.Visible = 'on';
                app.TxGainLabel.Visible = 'on';     app.TxGainValue.Visible = 'on';
                app.RxGainLabel.Visible = 'on';     app.RxGainValue.Visible = 'on';
            else
                app.NearFieldLabel.Visible = 'off'; app.NearFieldValue.Visible = 'off';
                app.TxGainLabel.Visible = 'off';    app.TxGainValue.Visible = 'off';
                app.RxGainLabel.Visible = 'off';    app.RxGainValue.Visible = 'off';
                app.NearFieldValue.Text = '-- m';
                app.TxGainValue.Text = '-- dBi';
                app.RxGainValue.Text = '-- dBi';
            end

            % --- Query distance interpolation ---
            query_d = app.QueryDistanceEditField.Value;

            eff_str = '';
            prx_str = '';

            % Far-field query
            if ~isempty(results_ideal) && query_d >= min(results_ideal.d_vec) && query_d <= max(results_ideal.d_vec)
                eff_q = interp1(results_ideal.d_vec, results_ideal.eff_system_pct, query_d);
                prx_q = interp1(results_ideal.d_vec, results_ideal.P_rx_dBm,      query_d);

                if isnan(eff_q)
                    eff_str = 'FF: in near-field';
                    prx_str = 'N/A';
                else
                    eff_str = sprintf('FF: %.4f%%', eff_q);
                    prx_str = sprintf('%.2f dBm', prx_q);

                    if ~isempty(results_real)
                        eff_r = interp1(results_real.d_vec, results_real.eff_system_pct, query_d);
                        prx_r = interp1(results_real.d_vec, results_real.P_rx_dBm,      query_d);
                        if ~isnan(eff_r)
                            eff_str = sprintf('FF: %.4f / %.4f%%', eff_q, eff_r);
                            prx_str = sprintf('%.2f / %.2f dBm', prx_q, prx_r);
                        end
                    end
                end
            end

            % Near-field query
            if ~isempty(results_nf) && query_d >= min(results_nf.d_vec) && query_d <= max(results_nf.d_vec)
                eff_nf_q = interp1(results_nf.d_vec, results_nf.eta_inductive_pct, query_d);
                if ~isnan(eff_nf_q)
                    if isempty(eff_str)
                        eff_str = sprintf('NF: %.4f%%', eff_nf_q);
                    else
                        eff_str = [eff_str sprintf(' | NF: %.4f%%', eff_nf_q)];
                    end
                elseif isempty(eff_str)
                    eff_str = 'NF: beyond radiansphere';
                end
            end

            if isempty(eff_str)
                eff_str = 'Out of range';
                prx_str = char(8212);
            end

            app.EffValue.Text = eff_str;
            if ~isempty(prx_str)
                app.PrxValue.Text = prx_str;
            else
                app.PrxValue.Text = char(8212);
            end

            % Labels
            has_real = ~isempty(results_real);
            has_nf   = ~isempty(results_nf);
            if has_real
                app.PrxLabel.Text = 'P_rx (I/R):';
                app.EffLabel.Text = [char(951) ' (I/R):'];
            elseif has_nf
                app.PrxLabel.Text = 'P_rx:';
                app.EffLabel.Text = [char(951) ' (FF/NF):'];
            else
                app.PrxLabel.Text = 'P_rx:';
                app.EffLabel.Text = [char(951) ':'];
            end
        end

        function computeRectennaFromLog(app)
            % Recomputes the rectenna efficiency curve from cached raw
            % LTspice voltage data using the current R_load value.
            % Formula: eta = (V_dc^2 / R_load) / P_in_W
            R_load = app.RloadEditField.Value;
            p_dbm  = app.ParsedLogData.p_dbm(:);
            v_dc   = app.ParsedLogData.v_dc(:);

            P_in_W = 10.^((p_dbm - 30) ./ 10);
            P_dc_W = v_dc.^2 ./ R_load;
            eta    = P_dc_W ./ P_in_W;

            % Clamp to [0, 1.0] and count violations
            n_clamped = sum(eta > 1.0 | eta < 0);
            eta = min(max(eta, 0), 1.0);

            app.RectennaCurve = [p_dbm, eta];

            % Update status label with point count and clamping warning
            status = sprintf('Log: %s (%d pts)', ...
                app.ParsedLogData.filename, length(p_dbm));
            if n_clamped > 0
                status = sprintf('%s (%d pts clamped)', status, n_clamped);
            end
            app.RectennaStatusLabel.Text = status;
            app.RectennaStatusLabel.FontColor = [0 0.5 0];
        end

    end

    % Callbacks that handle component events
    methods (Access = private)

        % ---------- Frequency Callbacks ----------
        function FrequencyEditFieldValueChanged(app, event)
            value = app.FrequencyEditField.Value;
            app.FrequencyMHzSlider.Value = log10(value * 1e6);
            updateHeuristics(app);
            updatePlot(app);
        end

        function FrequencyMHzSliderValueChanged(app, event)
            value = app.FrequencyMHzSlider.Value;
            app.FrequencyEditField.Value = round((10^value) / 1e6, 2);
            updateHeuristics(app);
            updatePlot(app);
        end

        % ---------- TX Antenna Callbacks ----------
        function TxAntennaEditFieldValueChanged(app, event)
            value = app.TxAntennaEditField.Value;
            app.TxAntennaSlider.Value = min(value, app.TxAntennaSlider.Limits(2));
            updatePlot(app);
        end

        function TxAntennaSliderValueChanged(app, event)
            app.TxAntennaEditField.Value = round(app.TxAntennaSlider.Value, 1);
            updatePlot(app);
        end

        % ---------- RX Antenna Callbacks ----------
        function RxAntennaEditFieldValueChanged(app, event)
            value = app.RxAntennaEditField.Value;
            app.RxAntennaSlider.Value = min(value, app.RxAntennaSlider.Limits(2));
            updatePlot(app);
        end

        function RxAntennaSliderValueChanged(app, event)
            app.RxAntennaEditField.Value = round(app.RxAntennaSlider.Value, 1);
            updatePlot(app);
        end

        % ---------- Max Distance ----------
        function MaxDistanceEditFieldValueChanged(app, event)
            updatePlot(app);
        end

        % ---------- Query Distance ----------
        function QueryDistanceEditFieldValueChanged(app, event)
            if ~isempty(app.LastResults) || ~isempty(app.LastNearfieldResults)
                updateReadouts(app, app.LastResults, app.LastRealisticResults, app.LastNearfieldResults);
            end
        end

        % ---------- Realistic Mode Toggle ----------
        function RealisticToggleValueChanged(app, event)
            if strcmp(app.RealisticToggle.Value, 'Realistic')
                app.RealisticPanel.Visible = 'on';
                updateHeuristics(app);
            else
                app.RealisticPanel.Visible = 'off';
            end
            updatePlot(app);
        end

        % ---------- Realistic Parameter Callbacks ----------
        function PathLossExpEditFieldValueChanged(app, event)
            updatePlot(app);
        end

        function PolarizationDropDownValueChanged(app, event)
            updatePlot(app);
        end

        function S11TxEditFieldValueChanged(app, event)
            updatePlot(app);
        end

        function S11RxEditFieldValueChanged(app, event)
            updatePlot(app);
        end

        function LhwEditFieldValueChanged(app, event)
            updatePlot(app);
        end

        % ---------- Auto Checkbox Callbacks ----------
        function AutoNCheckboxValueChanged(app, event)
            if app.AutoNCheckbox.Value
                app.PathLossExpEditField.Enable = 'off';
                updateHeuristics(app);
            else
                app.PathLossExpEditField.Enable = 'on';
            end
            updatePlot(app);
        end

        function AutoLhwCheckboxValueChanged(app, event)
            if app.AutoLhwCheckbox.Value
                app.LhwEditField.Enable = 'off';
                updateHeuristics(app);
            else
                app.LhwEditField.Enable = 'on';
            end
            updatePlot(app);
        end

        function AutoRectennaCheckboxValueChanged(app, event)
            if app.AutoRectennaCheckbox.Value
                app.RectennaCurve = [];
                app.ParsedLogData = [];
                app.LoadRectennaButton.Text = 'Load Sim Data';
                app.LoadRectennaButton.BackgroundColor = [0.85 0.93 1.0];
                app.RloadEditField.Enable = 'off';
                updateHeuristics(app);
            else
                app.LoadRectennaButton.Enable = 'on';
                if isempty(app.RectennaCurve)
                    app.RectennaStatusLabel.Text = 'No curve (using flat 60%)';
                    app.RectennaStatusLabel.FontColor = [0.5 0.5 0.5];
                end
            end
            updatePlot(app);
        end

        % ---------- Load / Clear Sim Data ----------
        function LoadRectennaButtonPushed(app, event)
            % --- Clear action: if data is already loaded, clear it ---
            if ~isempty(app.RectennaCurve)
                app.RectennaCurve = [];
                app.ParsedLogData = [];
                app.LoadRectennaButton.Text = 'Load Sim Data';
                app.LoadRectennaButton.BackgroundColor = [0.85 0.93 1.0];
                app.AutoRectennaCheckbox.Enable = 'on';
                app.RloadEditField.Enable = 'off';
                app.RectennaStatusLabel.Text = 'No curve (using flat 60%)';
                app.RectennaStatusLabel.FontColor = [0.5 0.5 0.5];
                updatePlot(app);
                return;
            end

            % --- Load action: file picker for .log or .csv ---
            [file, path] = uigetfile({'*.log;*.csv', 'Log & CSV (*.log, *.csv)'; '*.*', 'All Files'}, 'Select Data');
            if isequal(file, 0); return; end
            filepath = fullfile(path, file);

            [~, ~, ext] = fileparts(file);

            try
                if strcmpi(ext, '.log')
                    % ---- LTspice .log pathway ----
                    [p_dbm, v_dc] = parse_ltspice_log(filepath);
                    app.ParsedLogData = struct( ...
                        'p_dbm', p_dbm, ...
                        'v_dc', v_dc, ...
                        'filename', file);
                    app.RloadEditField.Enable = 'on';
                    computeRectennaFromLog(app);

                else
                    % ---- CSV pathway (existing) ----
                    app.RectennaCurve = load_rectenna_curve(filepath);
                    app.ParsedLogData = [];  % Clear ghost log data
                    app.RloadEditField.Enable = 'off';
                    app.RectennaStatusLabel.Text = sprintf('CSV: %s (%d pts)', ...
                        file, size(app.RectennaCurve, 1));
                    app.RectennaStatusLabel.FontColor = [0 0.5 0];
                end

                app.LoadRectennaButton.Text = 'Clear Data';
                app.LoadRectennaButton.BackgroundColor = [1.0 0.90 0.90];
                app.AutoRectennaCheckbox.Value = false;
                app.AutoRectennaCheckbox.Enable = 'off';
                updatePlot(app);

            catch err
                app.RectennaStatusLabel.Text = sprintf('Error: %s', err.message);
                app.RectennaStatusLabel.FontColor = [0.8 0 0];
            end
        end

        % ---------- R_load Live Update ----------
        function RloadEditFieldValueChanged(app, event)
            if ~isempty(app.ParsedLogData)
                computeRectennaFromLog(app);
                updatePlot(app);
            end
        end

        % ---------- Coil Panel Callbacks ----------
        function TxCoilDiamEditFieldValueChanged(app, event)
            value = app.TxCoilDiamEditField.Value;
            app.TxCoilDiamSlider.Value = min(max(value, app.TxCoilDiamSlider.Limits(1)), ...
                                              app.TxCoilDiamSlider.Limits(2));
            updatePlot(app);
        end

        function TxCoilDiamSliderValueChanged(app, event)
            app.TxCoilDiamEditField.Value = round(app.TxCoilDiamSlider.Value, 1);
            updatePlot(app);
        end

        function RxCoilDiamEditFieldValueChanged(app, event)
            value = app.RxCoilDiamEditField.Value;
            app.RxCoilDiamSlider.Value = min(max(value, app.RxCoilDiamSlider.Limits(1)), ...
                                              app.RxCoilDiamSlider.Limits(2));
            updatePlot(app);
        end

        function RxCoilDiamSliderValueChanged(app, event)
            app.RxCoilDiamEditField.Value = round(app.RxCoilDiamSlider.Value, 1);
            updatePlot(app);
        end

        function TxTurnsEditFieldValueChanged(app, event)
            updatePlot(app);
        end

        function RxTurnsEditFieldValueChanged(app, event)
            updatePlot(app);
        end

        function WireGaugeDropDownValueChanged(app, event)
            updatePlot(app);
        end

        % ---------- Physics Mode Toggle (Hybrid Zone) ----------
        function PhysicsModeDropDownValueChanged(app, event)
            updatePlot(app);
        end

        % ---------- Save / Clear Comparison ----------
        function LockGraphforComparisonButtonPushed(app, event)
            curve = struct();
            curve.d_vec = [];
            curve.eff_ideal = [];
            curve.eff_realistic = [];
            curve.has_realistic = false;
            curve.eff_nearfield = [];
            curve.has_nearfield = false;
            curve.label = '';

            if ~isempty(app.LastResults)
                curve.d_vec = app.LastResults.d_vec;
                curve.eff_ideal = app.LastResults.eff_system_pct;
                if ~isempty(app.LastRealisticResults)
                    curve.eff_realistic = app.LastRealisticResults.eff_system_pct;
                    curve.has_realistic = true;
                end
                curve.label = sprintf('[Saved] %.1f MHz | TX:%dcm RX:%dcm', ...
                    app.LastResults.freq_MHz, round(app.LastResults.D_tx_cm), ...
                    round(app.LastResults.D_rx_cm));
            end

            if ~isempty(app.LastNearfieldResults)
                if isempty(curve.d_vec)
                    curve.d_vec = app.LastNearfieldResults.d_vec;
                end
                curve.eff_nearfield = app.LastNearfieldResults.eta_inductive_pct;
                curve.has_nearfield = true;
                if isempty(curve.label)
                    curve.label = sprintf('[Saved] %.2f MHz (Inductive)', ...
                        app.LastNearfieldResults.freq_Hz / 1e6);
                end
            end

            if ~isempty(curve.d_vec)
                app.SavedCurves{end+1} = curve;
                updatePlot(app);
            end
        end

        function ClearGraphButtonPushed(app, event)
            app.SavedCurves = {};
            updatePlot(app);
        end
    end

    % Component initialization
    methods (Access = private)

        function createComponents(app)

            % ==================== FIGURE ====================
            app.UIFigure = uifigure('Visible', 'off');
            app.UIFigure.Position = [100 100 1250 800];
            app.UIFigure.Name = 'WPT Link Budget Calculator';
            app.UIFigure.Color = [0.94 0.94 0.96];

            % ==================== PLOT AXES ====================
            app.UIAxes = uiaxes(app.UIFigure);
            title(app.UIAxes, '')
            xlabel(app.UIAxes, 'Distance (m)')
            ylabel(app.UIAxes, 'System Efficiency (%)')
            app.UIAxes.Position = [65 30 1140 300];

            % ==================== FREQUENCY CONTROLS ====================
            % Extended range: 100 kHz (0.1 MHz) to 10 GHz for Phase 3 near-field support
            app.FrequencyEditField = uieditfield(app.UIFigure, 'numeric');
            app.FrequencyEditField.Limits = [0.1 10000];
            app.FrequencyEditField.ValueChangedFcn = createCallbackFcn(app, @FrequencyEditFieldValueChanged, true);
            app.FrequencyEditField.Position = [20 755 75 22];
            app.FrequencyEditField.Value = 2450;

            app.FrequencyLabel = uilabel(app.UIFigure);
            app.FrequencyLabel.Position = [100 750 80 30];
            app.FrequencyLabel.Text = {'Frequency'; '(MHz)'};

            app.FrequencyMHzSlider = uislider(app.UIFigure);
            app.FrequencyMHzSlider.Limits = [5 10];
            app.FrequencyMHzSlider.MajorTicks = [5 6 7 8 9 10];
            app.FrequencyMHzSlider.MajorTickLabels = {'100k', '1M', '10M', '100M', '1G', '10G'};
            app.FrequencyMHzSlider.ValueChangedFcn = createCallbackFcn(app, @FrequencyMHzSliderValueChanged, true);
            app.FrequencyMHzSlider.Position = [190 768 230 3];
            app.FrequencyMHzSlider.Value = log10(2450e6);

            % ==================== TX ANTENNA CONTROLS (DIAMETER) ====================
            app.TxAntennaEditField = uieditfield(app.UIFigure, 'numeric');
            app.TxAntennaEditField.Limits = [1 500];
            app.TxAntennaEditField.ValueChangedFcn = createCallbackFcn(app, @TxAntennaEditFieldValueChanged, true);
            app.TxAntennaEditField.Position = [20 705 75 22];
            app.TxAntennaEditField.Value = 10;

            app.TxAntennaLabel = uilabel(app.UIFigure);
            app.TxAntennaLabel.Position = [100 700 82 30];
            app.TxAntennaLabel.Text = {'TX Antenna'; 'Diam (cm)'};

            app.TxAntennaSlider = uislider(app.UIFigure);
            app.TxAntennaSlider.Limits = [1 100];
            app.TxAntennaSlider.ValueChangedFcn = createCallbackFcn(app, @TxAntennaSliderValueChanged, true);
            app.TxAntennaSlider.Position = [190 718 230 3];
            app.TxAntennaSlider.Value = 10;

            % ==================== RX ANTENNA CONTROLS (DIAMETER) ====================
            app.RxAntennaEditField = uieditfield(app.UIFigure, 'numeric');
            app.RxAntennaEditField.Limits = [1 500];
            app.RxAntennaEditField.ValueChangedFcn = createCallbackFcn(app, @RxAntennaEditFieldValueChanged, true);
            app.RxAntennaEditField.Position = [20 655 75 22];
            app.RxAntennaEditField.Value = 5;

            app.RxAntennaLabel = uilabel(app.UIFigure);
            app.RxAntennaLabel.Position = [100 650 82 30];
            app.RxAntennaLabel.Text = {'RX Antenna'; 'Diam (cm)'};

            app.RxAntennaSlider = uislider(app.UIFigure);
            app.RxAntennaSlider.Limits = [1 100];
            app.RxAntennaSlider.ValueChangedFcn = createCallbackFcn(app, @RxAntennaSliderValueChanged, true);
            app.RxAntennaSlider.Position = [190 668 230 3];
            app.RxAntennaSlider.Value = 5;

            % ==================== MAX DISTANCE ====================
            app.MaxDistanceEditField = uieditfield(app.UIFigure, 'numeric');
            app.MaxDistanceEditField.Limits = [0.5 1000];
            app.MaxDistanceEditField.ValueChangedFcn = createCallbackFcn(app, @MaxDistanceEditFieldValueChanged, true);
            app.MaxDistanceEditField.Position = [20 615 75 22];
            app.MaxDistanceEditField.Value = 5;

            app.MaxDistanceLabel = uilabel(app.UIFigure);
            app.MaxDistanceLabel.Position = [100 615 110 22];
            app.MaxDistanceLabel.Text = 'Max Distance (m)';

            % ==================== REALISTIC MODE TOGGLE ====================
            app.RealisticToggleLabel = uilabel(app.UIFigure);
            app.RealisticToggleLabel.Position = [20 585 120 22];
            app.RealisticToggleLabel.Text = 'Realistic Mode:';
            app.RealisticToggleLabel.FontWeight = 'bold';

            app.RealisticToggle = uiswitch(app.UIFigure, 'slider');
            app.RealisticToggle.Items = {'Ideal', 'Realistic'};
            app.RealisticToggle.Value = 'Ideal';
            app.RealisticToggle.ValueChangedFcn = createCallbackFcn(app, @RealisticToggleValueChanged, true);
            app.RealisticToggle.Position = [55 558 45 20];

            % ==================== REALISTIC CONSTRAINTS PANEL ====================
            app.RealisticPanel = uipanel(app.UIFigure);
            app.RealisticPanel.Title = 'Realistic Constraints';
            app.RealisticPanel.FontWeight = 'bold';
            app.RealisticPanel.ForegroundColor = [0.6 0.3 0.1];
            app.RealisticPanel.Position = [20 360 450 185];
            app.RealisticPanel.Visible = 'off';

            % --- Row 1: Path Loss Exponent + Auto + Polarization ---
            app.PathLossExpLabel = uilabel(app.RealisticPanel);
            app.PathLossExpLabel.Position = [10 130 90 22];
            app.PathLossExpLabel.Text = 'Path Loss Exp (n):';

            app.PathLossExpEditField = uieditfield(app.RealisticPanel, 'numeric');
            app.PathLossExpEditField.Limits = [2 6];
            app.PathLossExpEditField.ValueChangedFcn = createCallbackFcn(app, @PathLossExpEditFieldValueChanged, true);
            app.PathLossExpEditField.Position = [100 130 45 22];
            app.PathLossExpEditField.Value = 2;
            app.PathLossExpEditField.Enable = 'off';

            app.AutoNCheckbox = uicheckbox(app.RealisticPanel);
            app.AutoNCheckbox.Text = 'Auto';
            app.AutoNCheckbox.Value = true;
            app.AutoNCheckbox.ValueChangedFcn = createCallbackFcn(app, @AutoNCheckboxValueChanged, true);
            app.AutoNCheckbox.Position = [150 130 55 22];

            app.PolarizationLabel = uilabel(app.RealisticPanel);
            app.PolarizationLabel.Position = [215 130 85 22];
            app.PolarizationLabel.Text = 'Polarization:';

            app.PolarizationDropDown = uidropdown(app.RealisticPanel);
            app.PolarizationDropDown.Items = {'Co-polarized', '45° Mismatch', 'Cross-polarized'};
            app.PolarizationDropDown.ItemsData = [1.0, 0.5, 0.01];
            app.PolarizationDropDown.Value = 1.0;
            app.PolarizationDropDown.ValueChangedFcn = createCallbackFcn(app, @PolarizationDropDownValueChanged, true);
            app.PolarizationDropDown.Position = [305 130 120 22];

            % --- Row 2: Hardware Loss + Auto ---
            app.LhwLabel = uilabel(app.RealisticPanel);
            app.LhwLabel.Position = [10 100 90 22];
            app.LhwLabel.Text = 'L_hw (dB):';

            app.LhwEditField = uieditfield(app.RealisticPanel, 'numeric');
            app.LhwEditField.Limits = [0 10];
            app.LhwEditField.ValueChangedFcn = createCallbackFcn(app, @LhwEditFieldValueChanged, true);
            app.LhwEditField.Position = [105 100 50 22];
            app.LhwEditField.Value = 2.0;
            app.LhwEditField.Enable = 'off';

            app.AutoLhwCheckbox = uicheckbox(app.RealisticPanel);
            app.AutoLhwCheckbox.Text = 'Auto';
            app.AutoLhwCheckbox.Value = true;
            app.AutoLhwCheckbox.ValueChangedFcn = createCallbackFcn(app, @AutoLhwCheckboxValueChanged, true);
            app.AutoLhwCheckbox.Position = [162 100 50 22];

            % --- Row 3: S11 TX + S11 RX ---
            app.S11TxLabel = uilabel(app.RealisticPanel);
            app.S11TxLabel.Position = [10 70 120 22];
            app.S11TxLabel.Text = 'S11 TX (dB, e.g. -10):';

            app.S11TxEditField = uieditfield(app.RealisticPanel, 'numeric');
            app.S11TxEditField.Limits = [-60 0];
            app.S11TxEditField.ValueChangedFcn = createCallbackFcn(app, @S11TxEditFieldValueChanged, true);
            app.S11TxEditField.Position = [135 70 55 22];
            app.S11TxEditField.Value = -20;

            app.S11RxLabel = uilabel(app.RealisticPanel);
            app.S11RxLabel.Position = [200 70 120 22];
            app.S11RxLabel.Text = 'S11 RX (dB, e.g. -10):';

            app.S11RxEditField = uieditfield(app.RealisticPanel, 'numeric');
            app.S11RxEditField.Limits = [-60 0];
            app.S11RxEditField.ValueChangedFcn = createCallbackFcn(app, @S11RxEditFieldValueChanged, true);
            app.S11RxEditField.Position = [325 70 55 22];
            app.S11RxEditField.Value = -20;

            % --- Row 4: Rectenna Auto + Load/Clear Sim Data + Status ---
            app.AutoRectennaCheckbox = uicheckbox(app.RealisticPanel);
            app.AutoRectennaCheckbox.Text = 'Rectenna Auto';
            app.AutoRectennaCheckbox.Value = true;
            app.AutoRectennaCheckbox.ValueChangedFcn = createCallbackFcn(app, @AutoRectennaCheckboxValueChanged, true);
            app.AutoRectennaCheckbox.Position = [10 40 100 22];

            app.LoadRectennaButton = uibutton(app.RealisticPanel, 'push');
            app.LoadRectennaButton.ButtonPushedFcn = createCallbackFcn(app, @LoadRectennaButtonPushed, true);
            app.LoadRectennaButton.Position = [120 38 120 26];
            app.LoadRectennaButton.Text = 'Load Sim Data';
            app.LoadRectennaButton.BackgroundColor = [0.85 0.93 1.0];

            app.RectennaStatusLabel = uilabel(app.RealisticPanel);
            app.RectennaStatusLabel.Position = [245 40 180 22];
            app.RectennaStatusLabel.Text = 'Auto: initializing...';
            app.RectennaStatusLabel.FontColor = [0.5 0.5 0.5];

            % --- Row 5: R_load (Ω) — active only when .log file is loaded ---
            app.RloadLabel = uilabel(app.RealisticPanel);
            app.RloadLabel.Position = [10 10 90 22];
            app.RloadLabel.Text = 'R_load (Ω):';

            app.RloadEditField = uieditfield(app.RealisticPanel, 'numeric');
            app.RloadEditField.Limits = [1 100000];
            app.RloadEditField.ValueChangedFcn = createCallbackFcn(app, @RloadEditFieldValueChanged, true);
            app.RloadEditField.Position = [105 10 60 22];
            app.RloadEditField.Value = 1000;
            app.RloadEditField.Enable = 'off';

            % ==================== PHYSICS MODE TOGGLE (Hybrid Zone) ====================
            app.PhysicsModeLabel = uilabel(app.UIFigure);
            app.PhysicsModeLabel.Position = [460 755 90 22];
            app.PhysicsModeLabel.Text = 'Physics Mode:';
            app.PhysicsModeLabel.FontWeight = 'bold';
            app.PhysicsModeLabel.Visible = 'off';

            app.PhysicsModeDropDown = uidropdown(app.UIFigure);
            app.PhysicsModeDropDown.Items = {'Both Curves', 'Far-Field Only', 'Near-Field Only'};
            app.PhysicsModeDropDown.Value = 'Both Curves';
            app.PhysicsModeDropDown.ValueChangedFcn = createCallbackFcn(app, @PhysicsModeDropDownValueChanged, true);
            app.PhysicsModeDropDown.Position = [460 725 130 22];
            app.PhysicsModeDropDown.Visible = 'off';

            % ==================== READOUT PANEL ====================
            app.ReadoutPanel = uipanel(app.UIFigure);
            app.ReadoutPanel.Title = 'Link Budget Readout';
            app.ReadoutPanel.FontWeight = 'bold';
            app.ReadoutPanel.Position = [560 560 320 200];

            % Near-field boundary
            app.NearFieldLabel = uilabel(app.ReadoutPanel);
            app.NearFieldLabel.Position = [10 155 140 22];
            app.NearFieldLabel.Text = 'Near-Field Boundary:';
            app.NearFieldLabel.FontWeight = 'bold';

            app.NearFieldValue = uilabel(app.ReadoutPanel);
            app.NearFieldValue.Position = [160 155 170 22];
            app.NearFieldValue.Text = '-- m';
            app.NearFieldValue.FontColor = [0 0.35 0.65];

            % TX Gain
            app.TxGainLabel = uilabel(app.ReadoutPanel);
            app.TxGainLabel.Position = [10 130 65 22];
            app.TxGainLabel.Text = 'TX Gain:';
            app.TxGainLabel.FontWeight = 'bold';

            app.TxGainValue = uilabel(app.ReadoutPanel);
            app.TxGainValue.Position = [80 130 100 22];
            app.TxGainValue.Text = '-- dBi';
            app.TxGainValue.FontColor = [0 0.35 0.65];

            % RX Gain
            app.RxGainLabel = uilabel(app.ReadoutPanel);
            app.RxGainLabel.Position = [10 105 65 22];
            app.RxGainLabel.Text = 'RX Gain:';
            app.RxGainLabel.FontWeight = 'bold';

            app.RxGainValue = uilabel(app.ReadoutPanel);
            app.RxGainValue.Position = [80 105 100 22];
            app.RxGainValue.Text = '-- dBi';
            app.RxGainValue.FontColor = [0 0.35 0.65];

            % Query distance
            app.QueryDistanceLabel = uilabel(app.ReadoutPanel);
            app.QueryDistanceLabel.Position = [10 73 120 22];
            app.QueryDistanceLabel.Text = 'Query Distance (m):';
            app.QueryDistanceLabel.FontWeight = 'bold';

            app.QueryDistanceEditField = uieditfield(app.ReadoutPanel, 'numeric');
            app.QueryDistanceEditField.Limits = [0.01 10000];
            app.QueryDistanceEditField.ValueChangedFcn = createCallbackFcn(app, @QueryDistanceEditFieldValueChanged, true);
            app.QueryDistanceEditField.Position = [140 73 55 22];
            app.QueryDistanceEditField.Value = 1;

            % P_rx readout
            app.PrxLabel = uilabel(app.ReadoutPanel);
            app.PrxLabel.Position = [10 42 85 22];
            app.PrxLabel.Text = 'P_rx:';
            app.PrxLabel.FontWeight = 'bold';

            app.PrxValue = uilabel(app.ReadoutPanel);
            app.PrxValue.Position = [100 42 240 22];
            app.PrxValue.Text = '-- dBm';
            app.PrxValue.FontColor = [0 0.35 0.65];

            % Efficiency readout
            app.EffLabel = uilabel(app.ReadoutPanel);
            app.EffLabel.Position = [10 12 85 22];
            app.EffLabel.FontWeight = 'bold';
            app.EffLabel.Text = [char(951) ':'];

            app.EffValue = uilabel(app.ReadoutPanel);
            app.EffValue.Position = [100 12 240 22];
            app.EffValue.Text = '-- %';
            app.EffValue.FontColor = [0 0.35 0.65];

            % ==================== INDUCTIVE COIL PANEL (Phase 3) ====================
            app.CoilPanel = uipanel(app.UIFigure);
            app.CoilPanel.Title = 'Inductive Coil Parameters';
            app.CoilPanel.FontWeight = 'bold';
            app.CoilPanel.ForegroundColor = [0.1 0.45 0.2];
            app.CoilPanel.Position = [900 420 320 340];
            app.CoilPanel.Visible = 'off';  % Hidden at startup (farfield zone)

            % Row 1: TX Coil Diameter
            app.TxCoilDiamLabel = uilabel(app.CoilPanel);
            app.TxCoilDiamLabel.Position = [10 300 135 22];
            app.TxCoilDiamLabel.Text = 'TX Coil Diam (cm):';

            app.TxCoilDiamEditField = uieditfield(app.CoilPanel, 'numeric');
            app.TxCoilDiamEditField.Limits = [0.5 200];
            app.TxCoilDiamEditField.ValueChangedFcn = createCallbackFcn(app, @TxCoilDiamEditFieldValueChanged, true);
            app.TxCoilDiamEditField.Position = [150 300 55 22];
            app.TxCoilDiamEditField.Value = 10;  % 10 cm diameter = 5 cm radius

            app.TxCoilDiamSlider = uislider(app.CoilPanel);
            app.TxCoilDiamSlider.Limits = [1 60];
            app.TxCoilDiamSlider.ValueChangedFcn = createCallbackFcn(app, @TxCoilDiamSliderValueChanged, true);
            app.TxCoilDiamSlider.Position = [220 310 160 3];
            app.TxCoilDiamSlider.Value = 10;

            % Row 2: RX Coil Diameter
            app.RxCoilDiamLabel = uilabel(app.CoilPanel);
            app.RxCoilDiamLabel.Position = [10 260 135 22];
            app.RxCoilDiamLabel.Text = 'RX Coil Diam (cm):';

            app.RxCoilDiamEditField = uieditfield(app.CoilPanel, 'numeric');
            app.RxCoilDiamEditField.Limits = [0.5 200];
            app.RxCoilDiamEditField.ValueChangedFcn = createCallbackFcn(app, @RxCoilDiamEditFieldValueChanged, true);
            app.RxCoilDiamEditField.Position = [150 260 55 22];
            app.RxCoilDiamEditField.Value = 10;  % Symmetric default

            app.RxCoilDiamSlider = uislider(app.CoilPanel);
            app.RxCoilDiamSlider.Limits = [1 60];
            app.RxCoilDiamSlider.ValueChangedFcn = createCallbackFcn(app, @RxCoilDiamSliderValueChanged, true);
            app.RxCoilDiamSlider.Position = [220 270 160 3];
            app.RxCoilDiamSlider.Value = 10;

            % Row 3: TX Turns
            app.TxTurnsLabel = uilabel(app.CoilPanel);
            app.TxTurnsLabel.Position = [10 220 80 22];
            app.TxTurnsLabel.Text = 'TX Turns (N):';

            app.TxTurnsEditField = uieditfield(app.CoilPanel, 'numeric');
            app.TxTurnsEditField.Limits = [1 100];
            app.TxTurnsEditField.RoundFractionalValues = 'on';
            app.TxTurnsEditField.ValueChangedFcn = createCallbackFcn(app, @TxTurnsEditFieldValueChanged, true);
            app.TxTurnsEditField.Position = [100 220 50 22];
            app.TxTurnsEditField.Value = 10;

            % Row 4: RX Turns
            app.RxTurnsLabel = uilabel(app.CoilPanel);
            app.RxTurnsLabel.Position = [200 220 80 22];
            app.RxTurnsLabel.Text = 'RX Turns (N):';

            app.RxTurnsEditField = uieditfield(app.CoilPanel, 'numeric');
            app.RxTurnsEditField.Limits = [1 100];
            app.RxTurnsEditField.RoundFractionalValues = 'on';
            app.RxTurnsEditField.ValueChangedFcn = createCallbackFcn(app, @RxTurnsEditFieldValueChanged, true);
            app.RxTurnsEditField.Position = [290 220 50 22];
            app.RxTurnsEditField.Value = 10;

            % Row 5: Wire Gauge
            app.WireGaugeLabel = uilabel(app.CoilPanel);
            app.WireGaugeLabel.Position = [10 185 100 22];
            app.WireGaugeLabel.Text = 'Wire Gauge:';

            app.WireGaugeDropDown = uidropdown(app.CoilPanel);
            app.WireGaugeDropDown.Items = {'AWG 18', 'AWG 20', 'AWG 22', 'AWG 24', 'AWG 26', 'AWG 28', 'AWG 30'};
            app.WireGaugeDropDown.ItemsData = [18, 20, 22, 24, 26, 28, 30];
            app.WireGaugeDropDown.Value = 22;
            app.WireGaugeDropDown.ValueChangedFcn = createCallbackFcn(app, @WireGaugeDropDownValueChanged, true);
            app.WireGaugeDropDown.Position = [115 185 90 22];

            % Row 6: Computed inductance display
            app.CoilInfoLabel1 = uilabel(app.CoilPanel);
            app.CoilInfoLabel1.Position = [10 145 370 22];
            app.CoilInfoLabel1.Text = 'L_tx = -- uH  |  L_rx = -- uH';
            app.CoilInfoLabel1.FontColor = [0 0.35 0.65];

            % Row 7: Computed Q display
            app.CoilInfoLabel2 = uilabel(app.CoilPanel);
            app.CoilInfoLabel2.Position = [10 120 370 22];
            app.CoilInfoLabel2.Text = 'Q_tx = --  |  Q_rx = --';
            app.CoilInfoLabel2.FontColor = [0 0.35 0.65];

            % Row 8: Distributed element warning (hidden by default)
            app.DistElemWarning = uilabel(app.CoilPanel);
            app.DistElemWarning.Position = [10 80 375 40];
            app.DistElemWarning.Text = '';
            app.DistElemWarning.FontColor = [0.8 0 0];
            app.DistElemWarning.FontWeight = 'bold';
            app.DistElemWarning.WordWrap = 'on';
            app.DistElemWarning.Visible = 'off';

            % Row 9: Resonance assumption note
            app.CoilResonanceNote = uilabel(app.CoilPanel);
            app.CoilResonanceNote.Position = [10 10 375 55];
            app.CoilResonanceNote.Text = {[char(9889) ' Assumes resonant tuning (C_ext added to cancel']; ...
                                          'reactive impedance). Without resonance, this model'; ...
                                          'is inapplicable. See code comments for details.'};
            app.CoilResonanceNote.FontAngle = 'italic';
            app.CoilResonanceNote.FontColor = [0.4 0.4 0.4];
            app.CoilResonanceNote.FontSize = 10;

            % ==================== ACTION BUTTONS ====================
            app.LockGraphforComparisonButton = uibutton(app.UIFigure, 'push');
            app.LockGraphforComparisonButton.ButtonPushedFcn = createCallbackFcn(app, @LockGraphforComparisonButtonPushed, true);
            app.LockGraphforComparisonButton.Position = [900 760 150 30];
            app.LockGraphforComparisonButton.Text = 'Save for Comparison';
            app.LockGraphforComparisonButton.BackgroundColor = [0.85 0.93 1.0];

            app.ClearGraphButton = uibutton(app.UIFigure, 'push');
            app.ClearGraphButton.ButtonPushedFcn = createCallbackFcn(app, @ClearGraphButtonPushed, true);
            app.ClearGraphButton.Position = [1070 760 150 30];
            app.ClearGraphButton.Text = 'Clear Graph';
            app.ClearGraphButton.BackgroundColor = [1.0 0.90 0.90];

            % Show the figure after all components are created
            app.UIFigure.Visible = 'on';
        end
    end

    % App creation and deletion
    methods (Access = public)

        function app = App_ideal
            createComponents(app)
            registerApp(app, app.UIFigure)

            % Populate auto fields from default frequency BEFORE first plot
            updateHeuristics(app)
            updatePlot(app)

            if nargout == 0
                clear app
            end
        end

        function delete(app)
            delete(app.UIFigure)
        end
    end
end