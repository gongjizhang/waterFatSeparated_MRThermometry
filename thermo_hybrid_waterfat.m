function [m,wts,c,A,phi] = thermo_hybrid_waterfat(imgs, algp, scanp, lib, mswitch, phiswitch,minit,phiinit,hsmask)
%% Multi-echo fat-suppressed MR thermometry using iterative separation 
%% of baseline water and fat images
% Function to solve for heating, field shifts, and select a baseline in the
% presence of fat. 
%
% Creators: Megan Poorman, William Grissom
% Location: Vanderbilt University Institute of Imaging Science
% Created: 08/2014
% Updated: 05/2018
% Do not reproduce, distribute, or modify without proper citation according
% to license file
%
% Inputs:
%   imgs: Dynamic multi-echo images (Nx x Ny x Necho)
%   ----- algorithm params
%     algp.order = order;
%     algp.niter = number outer itrs;
%     algp.nmiter = number of m fit iters;
%     algp.nciter = nuber of c fit iters;
%     algp.lam = sparsity constraint;
%     algp.mthresh = threshold for significant heat;
%     algp.stopthresh = fit tolerance;
%     algp.modeltest = switch for model test precision measure;

%   ----- scan parameters
%     scanp.dim = [rows cols];
%     scanp.b0 = b0;
%     scanp.tes = tes;
%     scanp.prc = prc;
% 
%   ----- baseline library
%     lib.Wlib = Wlib;
%     lib.Flib = Flib;
%     lib.dw0lib = dw0lib;
%     lib.R2starlib = R2starlib;
%
% Output: 
%   m: frequency shit due to heating
%   wts: baseline weight
%   c: polynomial coefficients fit
%   A: polynomail basis functions
%   phi: Tx/Rx gain estimated

% M Poorman, W Grissom, Vanderbilt University Insitute of Imaging Science
% Created 2014
% Do not distribute publicly without above permission

%% --- Initialization --- %%
%--- construct 2nd order finite difference roughness penalty object
% keyboard
if isfield('algp','beta')
  R = Robject(ones(scanp.dim(1),scanp.dim(2)),'order',2,'beta',algp.beta,'type_denom','matlab');
else
  R = [];
end

%--- Initialize vars for backward compatibility
if ~isfield(algp,'usequadprog')
   algp.usequadprog = 1;
end
if ~isfield(algp,'nlib')
    algp.nlib = size(lib.Wlib,3);
end
if ~isfield(algp,'modeltest');
    algp.modeltest = 0;
end

%--- Create polynomial matrix of given order
[yc,xc] = meshgrid(linspace(-1/2,1/2,scanp.dim(1)),linspace(-1/2,1/2,scanp.dim(2)));
yc = yc(:);
xc = xc(:);
A = [];
for yp = 0:algp.order
    for xp = 0:(algp.order-yp)
        A = [A (xc.^xp).*(yc.^yp)];
    end
end

%--- initialize m,c,phi estimates
if ~exist('minit','var')
    m = zeros(scanp.dim(1),scanp.dim(2));
else
    m = minit;
end

if ~exist('phiinit','var')
    phi = zeros(scanp.dim(1),scanp.dim(2));
else
    phi = phiinit;
end 

if isfield(lib,'cinit')
    c = lib.cinit;
else
    c = zeros(size(A,2),1);
end

if scanp.dim(1)==scanp.dim(2)
    Ac = reshape(A*c,[scanp.dim(1) scanp.dim(2)]);
else
    Ac = reshape(A*c,[scanp.dim(2) scanp.dim(1)]).';
end



if length(scanp.dim) == 1 %assume square
    scanp.dim = [scanp.dim scanp.dim];
end

if algp.modeltest
    m =zeros(scanp.dim(1),scanp.dim(2));
end


%% --- Start l1-regularized iterations --- %%
% calculate a terrible cost that is guaranteed to get iterations going

cost = cost_eval(imgs,scanp,lib,zeros(size(lib.Wlib,3),1),Ac,m,phi,algp.lam); 
costOld = 2*cost;
ii = 0; % iteration counter

while costOld - cost > algp.stopthresh*costOld
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % run f_update with current m, c, phi
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    
    % build Z matrix using true values of Ac and m
    for jj = 1:size(lib.Wlib,3)
        Z(:,:,:,jj) = calcmeimgs(lib.Wlib(:,:,jj),lib.Flib(:,:,jj),...           
            scanp.tes,scanp.b0,lib.dw0lib(:,:,jj)+Ac,... 
            lib.R2starlib(:,:,jj),m,scanp.prc);
    end
    Z = Z.*repmat(exp(1i*phi),[1 1 size(Z,3) size(Z,4)]); 
    
    % call f_update with true hotspot and Ac
    if ii == 0  % in first iteration its best to use magnitude images for the fit,
        % in case there is a large phase shift between baselines
        % and dynamic image
        if algp.nlib < size(lib.Wlib,3)
            % compress the library down to the nlib entries that best 
            % correlate with the dynamic image
            [wts,algp.libinds] = f_update(abs(imgs),abs(Z),algp.usequadprog,algp.nlib);
            lib.Wlib = lib.Wlib(:,:,algp.libinds);
            lib.Flib = lib.Flib(:,:,algp.libinds);
            lib.dw0lib = lib.dw0lib(:,:,algp.libinds);
            lib.R2starlib = lib.R2starlib(:,:,algp.libinds);
        else
            wts = f_update(abs(imgs),abs(Z),algp.usequadprog);
        end
    else
        wts = f_update(imgs,Z,algp.usequadprog);
    end

    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % run c_update with current f, m
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%     keyboard
    cold = c; % WAG alleviate wraps
    Acold = Ac;
    for kk = 1:algp.nciter
%         keyboard
        % calculate and apply weights to baseline images
        Ztot = zeros([scanp.dim(1) scanp.dim(2) length(scanp.tes)]);
        for jj = 1:size(lib.Wlib,3)
            Z = calcmeimgs(lib.Wlib(:,:,jj),lib.Flib(:,:,jj),...
                scanp.tes,scanp.b0,lib.dw0lib(:,:,jj)+Ac,...
                lib.R2starlib(:,:,jj),m,scanp.prc);
            Ztot = Ztot + Z*wts(jj);
        end
        Ztot = Ztot.*repmat(exp(1i*phi),[1 1 size(Z,3)]);
% keyboard
        % update c
        c = c_update(imgs,Ztot,A,c,scanp.tes,scanp.prc);
        
        % recalculate frequency shift map
        if scanp.dim(1)==scanp.dim(2)
            Ac = reshape(A*c,[scanp.dim(1) scanp.dim(2)]);
        else
            Ac = reshape(A*c,[scanp.dim(2) scanp.dim(1)]).';
        end
 
    end
    
    if ii == 0 % also run for +/- 1/2/mean(tes), only on first itr
        disp('Doing update');
%         keyboard
        cnew = zeros(length(c),3);
        % store updated values of Ac, c
        costSv = cost_eval(imgs,scanp,lib,wts,Ac,m,phi,algp.lam);
        AcSv = Ac;
        cSv = c;
        
        %if c(1) > cold(1) we increased c in the updates. It is possible that we are in a local minimum and that the global min is more negative          
            % see if we get a lower error after subtracting
            % 2*pi/mean(scanp.tes)/2 from initial DC frequency coefficient,
            % and then updating
        %else we decreased c in the updates. It is possible that we are in a local minimum and that the global min is more positive
            % see if we get a lower error after adding
            % 2*pi/mean(scanp.tes)/2 to initial DC frequency coefficient,
            % and then updating    
        %other choice is we were on opposite side of hump, so let's try
            %both up and down to cover all bases
            if algp.order<1
                cnew(:,1) = cold - 2*pi/mean(scanp.tes)/2;
                cnew(:,2) = cold + 2*pi/mean(scanp.tes)/2;
                cnew(:,3) = cnew(:,2) + 2*pi/mean(scanp.tes);
            else
                cnew(:,1) = [cold(1)-2*pi/mean(scanp.tes)/2; cold(2:end)];
                cnew(:,2) = [cold(1)+2*pi/mean(scanp.tes)/2; cold(2:end)];
                cnew(:,3) = [cnew(1,2)+2*pi/mean(scanp.tes)/2; cold(2:end)];
            end

            if scanp.dim(1)==scanp.dim(2)
                Actest = reshape(A*cnew,[scanp.dim(1) scanp.dim(2) 3]);
            else
                Actest = permute(reshape(A*cnew,[scanp.dim(2) scanp.dim(1) 3]),[2 1 3]);
            end
%              keyboard       
        % try the update with each alternate initial point
        for dir = 1:size(Actest,3)
            ctest = cnew(:,dir);
            for kk = 1:algp.nciter
                % calculate and apply weights to baseline images
                Ztot = zeros([scanp.dim(1) scanp.dim(2) length(scanp.tes)]);
                for jj = 1:size(lib.Wlib,3)
                    Z = calcmeimgs(lib.Wlib(:,:,jj),lib.Flib(:,:,jj),...
                        scanp.tes,scanp.b0,lib.dw0lib(:,:,jj)+Actest(:,:,dir),...
                        lib.R2starlib(:,:,jj),m,scanp.prc);
                    Ztot = Ztot + Z*wts(jj);
                end
                %         keyboard
                Ztot = Ztot.*repmat(exp(1i*phi),[1 1 size(Z,3)]);

                % update c
                ctest = c_update(imgs,Ztot,A,ctest,scanp.tes,scanp.prc);

                % recalculate frequency shift map
                if scanp.dim(1)==scanp.dim(2)
                    Actest(:,:,dir) = reshape(A*ctest,[scanp.dim(1) scanp.dim(2)]);
                else
                    Actest(:,:,dir) = reshape(A*ctest,[scanp.dim(2) scanp.dim(1)]).';
                end 
            end
            cnew(:,dir) = ctest;
            
            % evaluate error for each case
            costAlt(dir) = cost_eval(imgs,scanp,lib,wts,Actest(:,:,dir),m,phi,algp.lam); 
            costAlt(isnan(costAlt)) = 0;
        end
        [minCost,ind] = min(costAlt);

%             if lower, keep these alternate values of c, Ac. 
            % If not, revert to default ones
            if minCost > costSv 
               c = cSv;
                Ac = AcSv;
            else
                c = cnew(:,ind);
                Ac = Actest(:,:,ind);
            end

    end
        
%     figure(2);im(Ac);
%     keyboard
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % run phi_update with current f, m,c
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % this accounts for any universal DC offsets due to reciever gain etc.
    if phiswitch
        for kk = 1:algp.nciter
            % calculate and apply weights to baseline images
            Ztot = zeros([scanp.dim(1) scanp.dim(2) length(scanp.tes)]);
            for jj = 1:size(lib.Wlib,3)
                Z = calcmeimgs(lib.Wlib(:,:,jj),lib.Flib(:,:,jj),...
                    scanp.tes,scanp.b0,lib.dw0lib(:,:,jj)+Ac,...
                    lib.R2starlib(:,:,jj),m,scanp.prc);
                Ztot = Ztot + Z*wts(jj);
            end
            Ztot = Ztot.*repmat(exp(1i*phi),[1 1 size(Z,3) size(Z,4)]); 

            % update phi
            phi = phi_update(imgs,Ztot,phi(:),scanp.tes,scanp.prc);

            % recalculate frequency shift map
            phi = reshape(phi,[scanp.dim(1) scanp.dim(2)]);

        end
    end
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % run m_update with current f, c
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    
    if mswitch
        if ~algp.modeltest
            for kk = 1:algp.nmiter

                % build Z matrix using true values of Ac and m
                Zw = zeros([scanp.dim(1) scanp.dim(2) length(scanp.tes)]);Zf = Zw;
                for jj = 1:size(lib.Wlib,3)
                    [~,foow,foof] = calcmeimgs(lib.Wlib(:,:,jj).*exp(1i*phi),lib.Flib(:,:,jj).*exp(1i*phi),...
                        scanp.tes,scanp.b0,lib.dw0lib(:,:,jj)+Ac,...
                        lib.R2starlib(:,:,jj),m,scanp.prc);
                    Zw = Zw + foow*wts(jj);
                    Zf = Zf + foof*wts(jj);   
                end

                % update m
                m = m_update(imgs-Zf,Zw,m,scanp.tes,scanp.prc,algp,[],R);

            end
        end
    end
    
    % report cost + iteration
    costOld = cost;ii = ii + 1;
    cost = cost_eval(imgs,scanp,lib,wts,Ac,m,phi,algp.lam);
    fprintf('l1-Penalized iteration %d: Cost = %0.2d\n',ii,cost);
%    keyboard
end
% return
%% --- Generate hotspot mask from regularization --- %%
if algp.modeltest
    %if performing precision model test do not mask
    if ~exist('hsmask','var')
        hsmask = ones(scanp.dim(1), scanp.dim(2));
    end

else
    % derive a mask of significant heating; apply it to m
    hsmask = (m < -sign(algp.lam)*algp.mthresh) + (m > sign(algp.lam)*algp.mthresh);
end
m = m.*hsmask;

%% --- Begin masked iterations to undo bias in m due to l1 penalty --- %%
% calculate a terrible cost that is guaranteed to get iterations going
cost = cost_eval(imgs,scanp,lib,zeros(size(lib.Wlib,3),1),Ac,m,phi);
costOld = 2*cost;
ii = 0; % iteration counter

while costOld - cost > algp.stopthresh*costOld
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % run f_update with current m, c
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    if ~algp.modeltest
        % build Z matrix using true values of Ac and m
        for jj = 1:size(lib.Wlib,3)
            Z(:,:,:,jj) = calcmeimgs(lib.Wlib(:,:,jj),lib.Flib(:,:,jj),...
                scanp.tes,scanp.b0,lib.dw0lib(:,:,jj)+Ac,...
                lib.R2starlib(:,:,jj),m,scanp.prc);
        end
        Z = Z.*repmat(exp(1i*phi),[1 1 size(Z,3) size(Z,4)]);
        % call f_update with true hotspot and Ac
        if ii == 1  % in first iteration its best to use magnitude images for the fit,
                    % in case there is a large phase shift between baselines
                    % and dynamic image
            wts = f_update(abs(imgs),abs(Z),algp.usequadprog);
        else
            wts = f_update(imgs,Z,algp.usequadprog);
        end

        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % run c_update with current f, m
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

        for kk = 1:algp.nciter

            % calculate and apply weights to baseline images
            Ztot = zeros([scanp.dim(1) scanp.dim(2) length(scanp.tes)]);
            for jj = 1:size(lib.Wlib,3)
                Z = calcmeimgs(lib.Wlib(:,:,jj),lib.Flib(:,:,jj),...
                    scanp.tes,scanp.b0,lib.dw0lib(:,:,jj)+Ac,...
                    lib.R2starlib(:,:,jj),m,scanp.prc);
                Ztot = Ztot + Z*wts(jj);
            end
            Ztot = Ztot.*repmat(exp(1i*phi),[1 1 size(Z,3) size(Z,4)]); 
            % update c
            c = c_update(imgs,Ztot,A,c,scanp.tes,scanp.prc);

            % recalculate frequency shift map
            if scanp.dim(1)==scanp.dim(2)
                Ac = reshape(A*c,[scanp.dim(1) scanp.dim(2)]);
            else
                Ac = reshape(A*c,[scanp.dim(2) scanp.dim(1)]).';
            end

        end

        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % run phi_update with current f, c,m
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        if phiswitch
            for kk = 1:algp.nciter

                % calculate and apply weights to baseline images
                Ztot = zeros([scanp.dim(1) scanp.dim(2) length(scanp.tes)]);
                for jj = 1:size(lib.Wlib,3)
                    Z = calcmeimgs(lib.Wlib(:,:,jj),lib.Flib(:,:,jj),...
                        scanp.tes,scanp.b0,lib.dw0lib(:,:,jj)+Ac,...
                        lib.R2starlib(:,:,jj),m,scanp.prc);
                    Ztot = Ztot + Z*wts(jj);
                end
                Ztot = Ztot.*repmat(exp(1i*phi),[1 1 size(Z,3) size(Z,4)]); 
                % update phi
                phi = phi_update(imgs,Ztot,phi(:),scanp.tes,scanp.prc);

                % recalculate frequency shift map
                phi = reshape(phi,[scanp.dim(1) scanp.dim(2)]);
            end
        end
    end
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % run m_update with current f, c
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    
    if mswitch
        for kk = 1:algp.nmiter

            % build Z matrix using true values of Ac and m
            Zw = zeros([scanp.dim(1) scanp.dim(2) length(scanp.tes)]);Zf = Zw;
            for jj = 1:size(lib.Wlib,3)
                [~,foow,foof] = calcmeimgs(lib.Wlib(:,:,jj).*exp(1i*phi),lib.Flib(:,:,jj).*exp(1i*phi),...
                    scanp.tes,scanp.b0,lib.dw0lib(:,:,jj)+Ac,...
                    lib.R2starlib(:,:,jj),m,scanp.prc);
                Zw = Zw + foow*wts(jj);
                Zf = Zf + foof*wts(jj);
            end

            % update m
            m = m_update(imgs-Zf,Zw,m,scanp.tes,scanp.prc,algp,hsmask,R); 

        end
    end
    
    % report cost + iteration
    costOld = cost;ii = ii + 1;
    cost = cost_eval(imgs,scanp,lib,wts,Ac,m,phi);
    fprintf('Masked iteration %d: Cost = %0.2d\n',ii,cost);

end


% function to evaluate the overall cost function
function cost = cost_eval(imgs,scanp,lib,wts,Ac,m,phi,lam)
% function cost = cost_eval(imgs,scanp,lib,wts,Ac,m,lam) 
Ztot = zeros([scanp.dim(1) scanp.dim(2) length(scanp.tes)]);
    for jj = 1:size(lib.Wlib,3)
        Z = calcmeimgs(lib.Wlib(:,:,jj),lib.Flib(:,:,jj),...
            scanp.tes,scanp.b0,lib.dw0lib(:,:,jj)+Ac,...
            lib.R2starlib(:,:,jj),m,scanp.prc);
        Ztot = Ztot + Z*wts(jj);
    end
%     keyboard
Ztot = Ztot.*repmat(exp(1i*phi),[1 1 size(Z,3) size(Z,4)]); 
cost = 1/2*norm(imgs(:)-Ztot(:))^2;
if exist('lam','var')
     cost = cost + norm(lam.*m,1); %
end


