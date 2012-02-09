function [hn, mining_queue, mining_stats] = ...
    esvm_mine_negatives(model, mining_queue)
% Compute "Hard-Negatives" for the images in the
% stream/queue [imageset/mining_queue] for the current model
% 
% Input Data:
% model: the input model
% mining_queue: the mining queue create from
%    esvm_initialize_mining_queue(imageset)
% 
% Returned Data: 
% hn: Kx1 cell array where hn{i} contains info for model i
% hn contains:
%   hn{:}.xs "features"
%   hn{:}.bbs "bounding boxes"
% mining_queue: the updated mining queue taking care of images we
%   already visited
% mining_stats: statistics about the number of detections, etc
%
% Copyright (C) 2011-12 by Tomasz Malisiewicz
% All rights reserved.
% 
% This file is part of the Exemplar-SVM library and is made
% available under the terms of the MIT license (see COPYING file).
% Project homepage: https://github.com/quantombone/exemplarsvm

imageset = model.data_set; 
params = model.params;

number_of_violating_images = 0;
number_of_windows = zeros(1,1);

violating_images = zeros(0,1);
empty_images = zeros(0,1);

% Force feature saving because we need features for training
params.detect_save_features = 1;

params.detect_exemplar_nms_os_threshold = ...
    params.train_exemplar_nms_os_threshold;
params.detect_max_scale = params.train_max_scale;

numpassed = 0;

model.total_mines = 0;

for i = 1:length(mining_queue)
  index = mining_queue{i}.index;
  I = toI(imageset{index});

  [rs,t] = esvm_detect(I, model, params);

  if isstruct(imageset{index}) ...
        && isfield(imageset{index},'objects') ...
        && length(imageset{index}.objects) > 0 ...
        && params.mine_skip_positive_objects == 1
    gtbbs = cat(1,imageset{index}.objects.bbox);

    os = getosmatrix_bb(rs.bbs{1},gtbbs);
    os = max(os,[],2);
    goods = find(os < params.mine_skip_positive_objects_os);
    rs.bbs{1} = rs.bbs{1}(goods,:);
    rs.xs{1} = rs.xs{1}(goods);
  end
  

  %NOTE(TJM): soft negative mining was experimental and is not used
  %anymore
  if isfield(params,'SOFT_NEGATIVE_MINING') && ...
        (params.SOFT_NEGATIVE_MINING==1)
    for j=1:length(rs.bbs)
      if size(rs.bbs{j},1) > 0
        top_det = rs.bbs{j}(1,:);
        os = getosmatrix_bb(rs.bbs{j},top_det);
        goods = find(os<params.SOFT_NEGATIVE_MINING_OS);
        rs.bbs{j} = rs.bbs{j}(goods,:);
        rs.xs{j} = rs.xs{j}(goods);
      end
    end
  end

  numpassed = numpassed + 1;

  curid_integer = index;  
  for q = 1:length(rs.bbs)
    if ~isempty(rs.bbs{q})
      rs.bbs{q}(:,11) = curid_integer;
    end
  end
 
  %% Make sure we only keep 3 times the number of violating windows
  clear scores
  scores{1} = [];
  for q = 1:1
    if ~isempty(rs.bbs{q})
      s = rs.bbs{q}(:,end);
      nviol = sum(s >= -1);
      [aa,bb] = sort(s,'descend');
      bb = bb(1:min(length(bb),...
                    ceil(nviol*params.train_keep_nsv_multiplier)));
      

      rs.xs{q} = rs.xs{q}(bb);    
      scores{q} = cat(2,s);
    end
  end
  
  addon ='';
  supersize = sum(cellfun(@(x)length(x),scores));
  if supersize > 0
    addon=sprintf(', max = %.3f',max(cellfun(@(x)max_or_this(x,-1000),scores)));
  end
  total = sum(cellfun(@(x)x.num_visited,mining_queue));

  fprintf(1,'Found %04d windows, image:%05d (#seen=%05d/%05d%s)\n',...
          supersize, index, ...
          total+1, length(mining_queue), addon);

  %increment how many times we processed this image
  mining_queue{i}.num_visited = mining_queue{i}.num_visited + 1;

  number_of_windows = number_of_windows + cellfun(@(x)length(x),scores)';
  
  clear curxs curbbs
  for q = 1:1 
    curxs{q} = [];
    curbbs{q} = [];
    if isempty(rs.xs{q})
      continue
    end
    
    goods = cellfun(@(x)prod(size(x)),rs.xs{q})>0;
    curxs{q} = cat(2,curxs{q},rs.xs{q}{goods});
    curbbs{q} = cat(1,curbbs{q},rs.bbs{q}(goods,:));
  end
  
  Ndets = cellfun(@(x)size(x,2),curxs);
  %if no detections, just skip image because there is nothing to store
  if sum(Ndets) == 0
    empty_images(end+1) = index;
    %continue
  end
  
  %an image is violating if it contains some violating windows,
  %else it is an empty image
  if max(cellfun(@(x)max_or_this(x,-1000),scores))>=-1
    if (mining_queue{i}.num_visited==1)
      number_of_violating_images = number_of_violating_images + 1;
    end 
    violating_images(end+1) = index;
  end

  for a = 1:1 
    xs{a}{i} = curxs{a};
    bbs{a}{i} = curbbs{a};
  end
  
  if (numpassed + model.total_mines >= ...
      params.train_max_mined_images) || ...
        (max(number_of_windows) >= params.train_max_windows_per_iteration) || ...
        (numpassed >= params.train_max_images_per_iteration)
    fprintf(1,['Stopping mining because we have %d windows from' ...
                                                ' %d new violators\n'],...
            max(number_of_windows), number_of_violating_images);
    break;
  end
end

if ~exist('xs','var')
  %If no detections from from anymodels, return an empty matrix
  for i = 1:1 
    hn.xs{i} = zeros(prod(size(model.model.w)),0);
    hn.bbs{i} = [];
  end
  mining_stats.num_violating = 0;
  mining_stats.num_empty = 0;
  
  return;
end

hn.xs = xs;
hn.bbs = bbs;

fprintf(1,'# Violating images: %d, #Non-violating images: %d\n', ...
        length(violating_images), length(empty_images));

mining_stats.num_empty = length(empty_images);
mining_stats.num_violating = length(violating_images);
mining_stats.total_mines = mining_stats.num_violating + mining_stats.num_empty;

%NOTE: there are several different mining scenarios possible here
%a.) dont process already processed images
%b.) place violating images at end of queue, eliminate free ones
%c.) place violating images at start of queue, eliminate free ones

if strcmp(params.queue_mode,'onepass') == 1
  %% MINING QUEUE UPDATE by removing already seen images
  mining_queue = update_mq_onepass(mining_queue, violating_images, ...
                                   empty_images);
elseif strcmp(params.queue_mode,'cycle-violators') == 1
  %% MINING QUEUE update by cycling violators to end of queue
  %mining_queue = update_mq_cycle_violators(mining_queue, violating_images, ...
  %                                 empty_images);
elseif strcmp(params.queue_mode,'front-violators') == 1
  %% MINING QUEUE UPDATE by removing already seen images, and
  %front-placing violators (used in CVPR11)
  %mining_queue = update_mq_front_violators(mining_queue, ...
  %                                         violating_images, ...
  %                                         empty_images);
else
  error(sprintf('Invalid queue mode: %s\n', ...
                params.queue_mode));
end


function mining_queue = update_mq_onepass(mining_queue, violating_images, ...
                                           empty_images)

%% Take the violating images and remove them from queue
mover_ids = find(cellfun(@(x)ismember(x.index,violating_images), ...
                         mining_queue));

mining_queue(mover_ids) = [];

%% We now take the empty images and remove them from queue
mover_ids = find(cellfun(@(x)ismember(x.index,empty_images), ...
                         mining_queue));

mining_queue(mover_ids) = [];

function mining_queue = update_mq_front_violators(mining_queue,...
                                                  violating_images, ...
                                                  empty_images)
%An update procedure where the violating images are pushed to front
%of queue, and empty images are removed

%% We now take the empty images and remove them from queue
mover_ids = find(cellfun(@(x)ismember(x.index,empty_images), ...
                         mining_queue));

%enders = mining_queue(mover_ids);
mining_queue(mover_ids) = [];


%% We now take the violating images and place them on the start of the queue
mover_ids = find(cellfun(@(x)ismember((x.index),violating_images), ...
                         mining_queue));

starters = mining_queue(mover_ids);
mining_queue(mover_ids) = [];
mining_queue = cat(2,starters,mining_queue);


function mining_queue = update_mq_cycle_violators(mining_queue,...
                                                  violating_images, ...
                                                  empty_images)
%An update procedure where the violating images are pushed to front
%of queue, and empty images are pushed to back

%% We now take the violating images and place them on the end of the queue
mover_ids = find(cellfun(@(x)ismember((x.index),violating_images), ...
                         mining_queue));

enders = mining_queue(mover_ids);
mining_queue(mover_ids) = [];
mining_queue = cat(2,mining_queue,enders);

%% We now take the empty images and remove them from the queue
mover_ids = find(cellfun(@(x)ismember(x.index,empty_images), ...
                         mining_queue));

enders = mining_queue(mover_ids);
mining_queue(mover_ids) = [];
