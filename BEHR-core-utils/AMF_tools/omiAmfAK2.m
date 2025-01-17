%OMIAMFAK2 - Compute OMI AMFs and AKs given scattering weights and NO2 profiles
%
%   [ amf, amfVis, amfCld, amfClr, sc_weights, avgKernel, no2ProfileInterp,
%     swPlev ] = omiAmfAK2( pTerr, pCld, cldFrac, cldRadFrac, pressure, 
%     dAmfClr, dAmfCld, temperature, no2Profile ) 
%
%   INPUTS:
%       pTerr - the 2D array of pixel surface pressures
%       pCld - the 2D array of pixel cloud pressures
%       pTropo - the 2D array of tropopause pressures
%       cldFrac - the 2D array of pixel geometric cloud fractions (field: CloudFraction)
%       cldRadFrac - the 2D array of pixel radiance cloud fractions (field: CloudRadianceFraction)
%       pressure - the vector of standard pressures to expect the scattering weights and profiles at
%       dAmfClr - the 3D array of scattering weight a.k.a. box-AMFs for clear sky conditions for each pixel.
%           The vertical coordinate should be along the first dimension, the second and third dimensions
%           should be the same as the two dimensions of 2D arrays
%       dAmfCld - the array of scattering weights for cloudy conditions. Same shape as dAmfClr.
%       temperature - the 3D array of temperature profiles for each pixel. Same shape as dAmfClr.
%       no2Profile - the 3D array of NO2 profiles for each pixel. Same shape as dAmfClr.
%
%       For all 3D inputs, the vertical levels must be at the pressures specified by "pressure".
%
%   OUTPUTS:
%       amf - the 2D array of AMFs for each pixel that will yield estiamted total columns (including
%           ghost column below clouds).
%       amfVis - the 2D array of AMFs for each pixel that will yield only visible columns (so EXCLUDING
%           ghost column below clouds)
%       amfCld - the 2D array of cloudy AMFs that are used for the total column AMF.
%       amfClr - the 2D array of clear sky AMFs, used for both AMFs.
%       sc_weights - the 3D array of combined scattering weights for the total column AMFs. These include
%           weights interpolated to the surface and cloud pressures.
%       avgKernel - the 3D array of averaging kerneles for the total column AMFs. These include kernels
%           interpolated to the surface and cloud pressure.
%       no2ProfileInterp - the NO2 profiles used for each pixel, interpolated to the surface and cloud
%           pressures as well.
%       swPlev - the 3D array of pressures as vertical coordinates for each pixel. Contains the standard
%           pressures from the input "pressure" plus surface and cloud pressures, if different from all the
%           standard pressures.
%

% Legacy comment block from Eric Bucsela (some inputs have been removed)
%..........................................................................
% Given a set of profiles, cloud and terrain parameters, computes AMF 
% and averging kernel profile. Also integrates to get vertical column densities.
% This is a combination of old codes omiAvgK.pro and calcAMF.pro (w/out uncert calcs)
% EJB (2008-05-30)
%
% Inputs:
%  pTerr = pressure of terrain (hPa)
%  pCld = pressure of cloud top (hPa)
%  cldFrac    = geometrical cloud fraction (0.0 to 1.0)
%  cldRadFrac = cloud radiance fraction (0.0 to 1.0)
%  pressure   = pressure vector from highest to lowest pressure (hPa)
%  dAmfClr    = dAMF profile vector for clear skies 
%  dAmfCld    = dAMF profile vector for overcast skies 
%  no2Profile= NO2 mixing ratio profile vector for AMF calculation (cm-3)
%  no2Profile2= NO2 mixing ratio profile vector for integration (cm-3)
%  temperature= temperature profile vector (K)
%
% Outputs:
%  amf    = air mass factor
%  amfCld = component of amf over cloudy part of scene (if any)
%  amfClr = component of amf over clear  part of scene (if any)
%
% Set keyword ak to compute these additional outputs:
%  avgKernel = averaging kernel vector
%  vcd = directly integrated NO2 profile (cm-2)
%  vcdAvgKernel = integrated product of NO2 profile and avg kernel (cm-2)
%
% Set keyword noghost for amf based on visible column only (otherwise, assume column to ground)
%
%    omiAmfAK, pTerr, pCld,  cldFrac,  cldRadFrac,  noGhost=noGhost,  ak=ak,         $ ;;scalar inputs
%              pressure,  dAMFclr,  dAMFcld,  temperature, no2Profile, no2Profile2, $ ;;vector inputs
%              amf, amfCld, amfClr, avgKernel, vcd, vcdAvgKernel                       ;;outputs%
%
%..........................................................................
%
%   JLL 13 May 2015: added output for scattering weights and averaging
%   kernel, both as the weighted average of clear and cloudy conditions.
%   The averaging kernel uses the preexisting code (just uncommented), the
%   scattering weights I added myself.
%
%   Josh Laughner <joshlaugh5@gmail.com> 

function [amf, amfVis, amfCld, amfClr, sc_weights_clr, sc_weights_cld, avgKernel, no2ProfileInterp, swPlev ] = omiAmfAK2(pTerr, pTropo, pCld, cldFrac, cldRadFrac, pressure, dAmfClr, dAmfCld, temperature, no2Profile)


% Each profile is expected to be a column in the no2Profile matrix.  Check
% for this by ensuring that the first dimension of both profile matrices
% has the same length as the pressure vector
E = JLLErrors;
if size(no2Profile,1) ~= length(pressure) 
    error(E.callError('profile_input','Profiles must be column vectors in the input matrices.  Ensure size(no2Profile,1) == length(pressure)'));
end
if size(dAmfClr,1) ~= length(pressure) || size(dAmfCld,1) ~= length(pressure);
    error(E.callError('dAmf_input','dAMFs must be column vectors in the input matrices.  Ensure size(dAmfxxx,1) == length(pressure)'));
end
if size(temperature,1) ~= length(pressure)
    error(E.callError('temperature_input','temperature must be a column vector.  Ensure size(temperature,1) == length(pressure)'));
end

alpha = 1 - 0.003 * (temperature - 220);   % temperature correction factor vector
% Keep NaNs in alpha, that way the scattering weights will be fill values
% for levels where we don't have temperature data.
alpha_i=max(alpha,0.1,'includenan');
alpha = min(alpha_i,10,'includenan');


% Integrate to get clear and cloudy AMFs
vcdGnd=nan(size(pTerr));
vcdCld=nan(size(pTerr));
amfClr=nan(size(pTerr));
amfCld=nan(size(pTerr));


% JLL 18 May 2015:
% Added preinitialization of these matrices, also nP will be needed to pad
% output vectors from integPr2 to allow concatenation of scattering weights
% vectors into a matrix (integPr2 will return a shorter vector if one or
% both of the pressures to interpolate to is already in the pressure
% vector). We add two to the first dimension of these matrices to make room
% for the three interpolated pressures.
padvec = zeros(1,ndims(no2Profile));
padvec(1) = 3;
swPlev=nan(size(no2Profile)+padvec);
swClr=nan(size(no2Profile)+padvec);
swCld=nan(size(no2Profile)+padvec);
no2ProfileInterp=nan(size(no2Profile)+padvec);
nP = size(swPlev,1);


for i=1:numel(pTerr)
    no2Profile_i = no2Profile(:,i);
    clearSW_i = no2Profile(:,i) .* dAmfClr(:,i) .* alpha(:,i);
    cloudySW_i = (no2Profile(:,i) .* dAmfCld(:,i) .* alpha(:,i));
    
    if all(isnan(no2Profile_i)) || all(isnan(clearSW_i)) || all(isnan(cloudySW_i))
        % 16 Apr 2018: found that AMFs were still being calculated if all
        % of one type of scattering weight was NaNs, but not the other.
        % This happens when, e.g., the MODIS albedo is a NaN so the clear
        % sky scattering weights are all NaNs but the cloudy ones are not.
        % That leads to a weird case where a pixel that is not necessarily
        % 100% cloudy is being calculated with a 0 for the clear sky AMF.
        % This is undesired behavior, we would rather just not retrieve
        % pixels for which we do not have surface data.
        continue
    end
    
    vcdGnd(i) = integPr2(no2Profile(:,i), pressure, pTerr(i), pTropo(i), 'fatal_if_nans', true);
    if cldFrac(i) ~= 0 && cldRadFrac(i) ~= 0 && pCld(i)>pTropo(i)
        vcdCld(i) = integPr2(no2Profile(:,i), pressure, pCld(i), pTropo(i), 'fatal_if_nans', true);
    else
        vcdCld(i)=0;
    end
    
    if cldFrac(i) ~= 1 && cldRadFrac(i) ~= 1
        amfClr(i) = integPr2(clearSW_i, pressure, pTerr(i), pTropo(i), 'fatal_if_nans', true) ./ vcdGnd(i);
    else
        amfClr(i)=0;
    end
    
    if cldFrac(i) ~= 0 && cldRadFrac(i) ~= 0 && pCld(i)>pTropo(i)
        cldSCD=integPr2(cloudySW_i, pressure, pCld(i), pTropo(i), 'fatal_if_nans', true);
        amfCld(i) = cldSCD ./ vcdGnd(i);
    else
        amfCld(i)=0;
    end

    
    % JLL 19 May 2015:
    % Added these lines to interpolate to the terrain & cloud pressures and
    % output a vector - this resulted in better agreement between our AMF and
    % the AMF calculated from "published" scattering weights when we
    % published unified scattering weights, so this probably still helps
    % with the averaging kernels
    [~, ~, this_no2ProfileInterp] = integPr2(no2Profile(:,i), pressure, pTerr(i), pTropo(i), 'interp_pres', [pTerr(i), pCld(i),pTropo(i)], 'fatal_if_nans', true);
    [~,this_swPlev,this_swClr] = integPr2((dAmfClr(:,i).*alpha(:,i)), pressure, pTerr(i), pTropo(i), 'interp_pres', [pTerr(i), pCld(i),pTropo(i)], 'fatal_if_nans', true);
    [~,~,this_swCld] = integPr2((dAmfCld(:,i).*alpha(:,i)), pressure, pCld(i), pTropo(i), 'interp_pres', [pTerr(i), pCld(i),pTropo(i)], 'fatal_if_nans', true);
    
    if ~iscolumn(this_swPlev)
        E.badvar('this_swPlev','Must be a column vector');
    elseif ~iscolumn(this_swClr)
        E.badvar('this_swClr', 'Must be a column vector');
    elseif ~iscolumn(this_swCld)
        E.badvar('this_swCld', 'Must be a column vector');
    elseif ~iscolumn(this_no2ProfileInterp)
        E.badvar('this_no2ProfileInterp', 'Must be a column vector');
    end
    
    % Pad with NaNs if there are fewer than nP (number of pressures in the
    % input pressure vector + 2 for the interpolated pressures) values.
    % integPr2 outputs vectors with nP values, unless one of the interpolated
    % pressures is already in the input pressure vector.
    this_swPlev = padarray(this_swPlev, nP - length(this_swPlev), nan, 'post');
    this_swClr = padarray(this_swClr, nP -  length(this_swClr), nan, 'post');
    this_swCld = padarray(this_swCld, nP - length(this_swCld), nan, 'post');
    this_no2ProfileInterp = padarray(this_no2ProfileInterp, nP - length(this_no2ProfileInterp), nan, 'post');
    
    swPlev(:,i) = this_swPlev;
    swClr(:,i) = this_swClr;
    swCld(:,i) = this_swCld;
    no2ProfileInterp(:,i) = this_no2ProfileInterp;

end

% Combine clear and cloudy parts of AMFs to calculate an AMF that corrects
% multiplicatively for the ghost column. It does so by including the ghost
% column in the VCD in the denominator of the AMF, which makes the AMF the
% ratio of the modeled (visible) SCD to the TOTAL VCD.
%
% We also calculate an AMF that will produce a visible-only VCD by
% effectively replacing the denominator with the modeled visible only VCD.

amf = cldRadFrac .* amfCld + (1-cldRadFrac).*amfClr;
amf(~isnan(amf)) = max(amf(~isnan(amf)), behr_min_amf_val());   % clamp at min value (2008-06-20), but don't replace NaNs with the min value (2016-05-12)

amfVis = amf .* vcdGnd ./ (vcdCld .* cldFrac + vcdGnd .* (1 - cldFrac));
amfVis(~isnan(amfVis)) = max(amfVis(~isnan(amfVis)), behr_min_amf_val());

% There is an alternate way of calculating a visible-only AMF: calculate a
% cloudy visible-only AMF by dividing the cloud modeled SCD by an
% above-cloud only modeled VCD instead of the to-ground VCD. Then weight
% these together by the cloud radiance fraction:
%
%   A_vis = (1-f) * A_clr + f * A_cld_vis
%         = (1-f) * S_clr / V_clr + f * S_cld / V_cld_vis
%
% Talking with Jim Gleason, he saw no reason that either representation
% would be invalid, and BEHR v2.1C used this alternate formulation.
%
% However, later I heard back from Eric Bucsela about this, and he pointed
% out that the physical interpretation of this alternate method is less
% clear. He generally thinks of AMFs as "what you should see divided by
% what you should want", so that when you divide what you actually see by
% the AMF, you get what you want. Since we see the SCD and want the VCD, we
% really want our visible AMF to be:
%
%   A_vis = SCD / VCD_vis 
%         = [(1-f) * S_clr + f * S_cld] / [(1-f) * V_clr + f * V_cld_vis]
%
% which is subtly different because now everything is one fraction.
% Algebraically, this form is equivalent to multiplying the total-column
% AMF by the ratio of the visible and total VCDs. This also seems to
% produce better agreement if you try to reproduce the AMF with the
% scattering weights.
%
% Eric also pointed out that the visible VCD should be a sum of clear and
% cloudy VCDs weighted by the geometric cloud fraction, not the radiance
% cloud fraction, b/c in that part we don't want to give more weight to the
% brighter cloudy part of the pixel.
%
%   -- J. Laughner, 19 Jul 2017



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Now compute averaging kernel %
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

if nargout > 4
    % This is only done for the total column, on the assumption that most
    % modelers would want to compare total column against their modeled
    % column.
    
    % These 2 sets of lines are an approximation of what is done in the OMI
    % NO2 algorithm
    avgKernel = nan(size(swPlev));
    sc_weights = nan(size(swPlev));
    sc_weights_clr = swClr;
    sc_weights_cld = swCld;
    
    for i=1:numel(pTerr)
        % JLL 19 May 2015 - pull out the i'th vector, this will allow us
        % to remove nans for AMF calculations where needed, and also
        % check that all vectors have NaNs in the same place.
        
        swPlev_i = swPlev(:,i);
        swClr_i = swClr(:,i);
        swCld_i = swCld(:,i);
        not_nans_i = ~isnan(swClr_i) & ~isnan(swCld_i);
        if ~all(not_nans_i == (~isnan(swClr_i) | ~isnan(swCld_i)))
            % Error called if there are NaNs present in one but not both of
            % these vectors. Previously had checked if the NaNs matched
            % those in the pressure levels, but once I fixed it so that
            % alpha retained NaNs that were in temperature, that was no
            % longer useful, since pressure will never have NaNs unless
            % they were appended to ensure equal length vectors when
            % surface, cloud, or tropopause pressure are one of the
            % standard pressures, but the scattering weights will have NaNs
            % where the WRF temperature profile doesn't reach.
            E.callError('nan_mismatch','NaNs are not the same in the swPlev, swClr, and swCld vectors');
        end
        
        ii = swPlev_i > pTerr(i) & ~isnan(swPlev_i);
        sc_weights_clr(ii,i) = 1e-30;
        swClr_i(ii)=1e-30;
        
        ii = swPlev_i > pCld(i) & ~isnan(swPlev_i);
        swCld_i(ii)=1e-30;
        sc_weights_cld(ii,i) = 1e-30;
        
        % 17 Nov 2017 - switched to outputting separate clear and cloudy
        % scattering weights
        sc_weights(:,i) = (cldRadFrac(i).*swCld_i + (1-cldRadFrac(i)).*swClr_i);
        
        avgKernel(:,i) = sc_weights(:,i) ./ amf(i); % JLL 19 May 2015 - changed to use the scattering weights we're already calculating.
    end
end
