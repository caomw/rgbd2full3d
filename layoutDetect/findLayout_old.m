function data = findLayout(data, opt)
  load ([fileparts( mfilename('fullpath') ) '/../config/layoutLocation.mat']);
  load ([fileparts( mfilename('fullpath') ) '/../config/layoutModel.mat']);
  
  opt.tolErr = 0.025; % sigma of point distribution, 95% are within 2 sigma (0.05*Z)
  opt.tolPara = 0.07799; % sigma cos > tolPara, we think two planes are parallel
  opt.layoutLoc = layoutLoc;
  sampleLabel = {'hceil', 'hfloor', 'frontwall', 'leftwall', 'rightwall'};
  
  layoutThreshold =  [0.0571 1.3018 0.4777 0.2355 0.1029]; % from .5 recall
  data.coord = cat(2, data.X(:), data.Y(:), data.Z(:));
  bbox_3d = [min(data.coord); max(data.coord)]';
  norm_3d = reshape(data.normal, [], 3);
  result = struct('type', {}, 'plane', [], 'mask', [], 'vertices', [], 'faces', []);
  cnt = 0;
  for s=layoutLabel
    s = s{1};
    badFeat = [];
    badLabel = [];
    badLocation = [];
    if strcmp(s, 'hceil')
      h = max(data.Y(:)); p = [0 -1 0 0 ]; if (h<0), continue; end
    elseif strcmp(s, 'hfloor')
      h = min(data.Y(:)); p = [0 -1 0 0 ]; if (h>0), continue; end
    elseif strcmp(s, 'frontwall')
      h = min(data.Z(:)); p = [0 0 -1 0 ]; if (h>0), continue; end
    elseif strcmp(s, 'leftwall')
      h = min(data.X(:)); p = [-1 0 0 0 ]; if (h>0), continue; end
    elseif strcmp(s, 'rightwall')
      h = max(data.X(:)); p = [-1 0 0 0 ]; if (h<0), continue; end
    end

    bad = sign(h)*(1e-3:opt.grid_size:(abs(h)+opt.grid_size));
    for v = bad
      badLabel = [badLabel, s];
      badLocation = [badLocation, v];
      % fake plane, for feature extraction
      p(4) = v;
      [label1, feat, v1] = getLayoutFeatures(p, data, opt);
      if ~strcmp(s, label1) || v~=v1
        error('Feature extraction error');
      end
      badFeat = [badFeat, feat.^.5];
    end
    % do nms
    id = find(ismember(layoutLabel, s)); lmodel = layoutModel{id};
    testData = badFeat';
    testData = normalize_zero_mean(testData, lmodel.trainMeans);
    testData = normalize_unit_var(testData, lmodel.trainStds);
    %[p, acc, score] = svmpredict(ones(size(testData,1), 1), testData, lmodel.model);
    [p, acc, score] = liblinearpredict(ones(size(testData,1), 1), testData, lmodel.model);
    score = score*(2*(lmodel.model.Label(1)==2)-1);
    nmsGrid = opt.nms/opt.grid_size;
    isLocalMax = (score == ordfilt2(score, nmsGrid*2+1, ones(nmsGrid*2+1, 1)));
    isLocalMax = isLocalMax & score>layoutThreshold(id); % or change the threshold here

    v = bad(isLocalMax);
    if isempty(v) && strcmp(s, 'hfloor')
      v = min(data.Y(:));
    end
    
    % render proposed surfaces
    for h = v
      cnt = cnt + 1;
      result(cnt).type = s;
      
      switch(s)
        case 'hceil'
          result(cnt).plane = [0 -1 0 h ];
          m = data.Y> h;
          result(cnt).mask = ones(size(data.depths));
          m1 = normpdf(data.Y(m), h, abs(data.Z(m))*opt.tolErr) ./ normpdf(0,0,abs(data.Z(m))*opt.tolErr);
          m2 = (norm_3d(m,:)*result(cnt).plane(1:3)').^2;
          result(cnt).mask(m) = m1.*m2;
        case 'hfloor'
          result(cnt).plane = [0 -1 0 h ];
          m = data.Y< h;
          result(cnt).mask = ones(size(data.depths));
          m1 = normpdf(data.Y(m), h, abs(data.Z(m))*opt.tolErr) ./ normpdf(0,0,abs(data.Z(m))*opt.tolErr);
          m2 = (norm_3d(m,:)*result(cnt).plane(1:3)').^2;
          result(cnt).mask(m) = m1.*m2;
        case 'frontwall'
          result(cnt).plane = [0 0 -1 h ];
          m = data.Z< h;
          result(cnt).mask = ones(size(data.depths));
          m1 = normpdf(data.Z(m), h, abs(data.Z(m))*opt.tolErr) ./ normpdf(0,0,abs(data.Z(m))*opt.tolErr);
          m2 = (norm_3d(m,:)*result(cnt).plane(1:3)').^2;
          result(cnt).mask(m) = m1.*m2;
        case 'leftwall'
          result(cnt).plane = [-1 0 0 h ];
          m = data.X< h;
          result(cnt).mask = ones(size(data.depths));
          m1 = normpdf(data.X(m), h, abs(data.Z(m))*opt.tolErr) ./ normpdf(0,0,abs(data.Z(m))*opt.tolErr);
          m2 = (norm_3d(m,:)*result(cnt).plane(1:3)').^2;
          result(cnt).mask(m) = m1.*m2;
        case 'rightwall'
          result(cnt).plane = [-1 0 0 h ];
          m = data.X> h;
          result(cnt).mask = ones(size(data.depths));
          m1 = normpdf(data.X(m), h, abs(data.Z(m))*opt.tolErr) ./ normpdf(0,0,abs(data.Z(m))*opt.tolErr);
          m2 = (norm_3d(m,:)*result(cnt).plane(1:3)').^2;
          result(cnt).mask(m) = m1.*m2;
      end
      
      % find connected component and add holes
      holemap = result(cnt).mask<0.05;
      
      cc = bwconncomp( result(cnt).mask<0.121 );
      numPixels = cellfun(@numel,cc.PixelIdxList);
      
      v = double(bbox_3d(~(result(cnt).plane(1:3)), :));
      in_poly = [v(1,1) v(1,1) v(1,2) v(1,2);
                 v(2,1) v(2,2) v(2,2) v(2,1)]';
      
      nHoles = 0; hole_poly = {};
      for ii=1:numel(numPixels)
        if numPixels(ii)<opt.too_small, continue; end
        % project points to the plane and find bbox
        xy = data.coord(cc.PixelIdxList{ii}, :);
        r = h ./ xy(:, find(result(cnt).plane(1:3)));
        xy = bsxfun(@times, xy, r);
        xy = [min(xy); max(xy)]';
        xy = xy(~(result(cnt).plane(1:3)), :);
        nHoles = nHoles + 1;
        hole_poly{nHoles} = double([xy(1,1) xy(1,1) xy(1,2) xy(1,2);
                             xy(2,1) xy(2,2) xy(2,2) xy(2,1)]');
      end
      validHoles = ones(nHoles, 1);
      for ii=1:numel(hole_poly)
        for jj=(ii+1):numel(hole_poly)
          if ((hole_poly{ii}(3,1)>hole_poly{jj}(1,1)) && (hole_poly{jj}(3,1)>hole_poly{ii}(1,1))) && ...
             ((hole_poly{ii}(3,2)>hole_poly{jj}(1,2)) && (hole_poly{jj}(3,2)>hole_poly{ii}(1,2)))
            validHoles(jj)=0;
            hole_poly{ii}([1,2],1) = min(hole_poly{ii}(1,1), hole_poly{jj}(1,1));
            hole_poly{ii}([3,4],1) = max(hole_poly{ii}(3,1), hole_poly{jj}(3,1));
            hole_poly{ii}([1,4],2) = min(hole_poly{ii}(1,2), hole_poly{jj}(1,2));
            hole_poly{ii}([2,3],2) = max(hole_poly{ii}(3,2), hole_poly{jj}(3,2));
          end
        end
      end
      hole_poly = {hole_poly{find(validHoles)}}; nHoles = sum(validHoles);
      %hole_poly = {}; nHoles=0;
      v_2d = cat(1, in_poly, hole_poly{:});
      C = [];
      for k=1:numel(hole_poly)
        C=[C; k*4+1 k*4+2; k*4+2 k*4+3; k*4+3 k*4+4; k*4+4 k*4+1];
      end
      if isempty(C)
        m = DelaunayTri(v_2d(:,1), v_2d(:,2));
      else
        m = DelaunayTri(v_2d(:,1), v_2d(:,2), C);
      end
      n = size(m.Triangulation, 1);
      not_hole = true(n, 1);
      center_pos = zeros(n, 2);
      for k=1:n
        center_pos(k, :) = mean(m.X(m.Triangulation(k,:), :));
      end
      not_hole = inpolygon(center_pos(:,1), center_pos(:,2), in_poly(:,1), in_poly(:,2) );
      for k=1:nHoles
        not_hole = not_hole & ~inpolygon(center_pos(:,1), center_pos(:,2), hole_poly{k}(:,1), hole_poly{k}(:,2) );
      end
      [~, idx] = min(pdist2(v_2d, m.X));
      v_3d = zeros(size(v_2d,1), 3);
      v_3d(:, ~result(cnt).plane(1:3)) = v_2d;
      v_3d(:, find(result(cnt).plane(1:3))) = h;
      result(cnt).vertices = v_3d(idx, :);
      result(cnt).faces = m.Triangulation(not_hole, :);
    end
  end
  
  fvc=struct('vertices', [], 'faces', []);
  for i=1:numel(result)
    fvc.faces = cat(1, fvc.faces, result(i).faces+size(fvc.vertices, 1));
    fvc.vertices = cat(1, fvc.vertices, result(i).vertices);
  end
  fvc.vertices = fvc.vertices*data.R';
  data.layoutProp.fvc=fvc; data.layoutProp.info=result;
  
  if opt.debug, figure(2), clf, imshow(kinectCamera(fvc)); end
end