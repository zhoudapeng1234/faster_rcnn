function save_model_path = proposal_train(conf, imdb_train, roidb_train, train_key, varargin)
% revisit by hyli
% all brand new

ip = inputParser;
ip.addRequired('conf',                                      @isstruct);
ip.addRequired('imdb_train',                                @iscell);
ip.addRequired('roidb_train',                               @iscell);
ip.addRequired('train_key',                                 @isstr);

ip.addParameter('detect_exist_train_file', true,            @islogical);
ip.addParameter('do_val',               false,              @islogical);
ip.addParameter('imdb_val',             struct(),           @isstruct);
ip.addParameter('roidb_val',            struct(),           @isstruct);
ip.addParameter('val_iters',            8000,                @isscalar);
ip.addParameter('val_interval',         5000,               @isscalar);
ip.addParameter('snapshot_interval',    10000,              @isscalar);
% Max pixel size of a scaled input image
ip.addParameter('solver_def_file',      '',                 @isstr);
ip.addParameter('net_file',             '',                 @isstr);
ip.addParameter('cache_name',           'Zeiler_conv5',     @isstr);
ip.addParameter('debug',                false,              @isscalar);
ip.addParameter('solverstate',          '',                 @isstr);
ip.addParameter('share_data_name',      '',                 @isstr);
ip.parse(conf, imdb_train, roidb_train, train_key, varargin{:});
opts = ip.Results;

debug = opts.debug;
train_data_name_str = opts.train_key;
cache_dir = fullfile(pwd, 'output', 'rpn_cachedir', ...
    opts.cache_name, train_data_name_str);

%% if the trained model is saved, skip the following and return
if ~debug  
    % the famous 'final.caffemodel'
    save_model_path = fullfile(cache_dir, 'final.caffemodel');
    if exist(save_model_path, 'file')
        fprintf('find the final model, skip training ...\n');
        return;
    end
end

%% init
% init caffe log
mkdir_if_missing([cache_dir '/caffe_log']);
caffe_log_file_base = fullfile(cache_dir, 'caffe_log/train_');
caffe.init_log(caffe_log_file_base);
% init matlab log
timestamp = datestr(datevec(now()), 'yyyymmdd_HHMMSS');
mkdir_if_missing(fullfile(cache_dir, 'matlab_log'));
log_file = fullfile(cache_dir, 'matlab_log', ['train_', timestamp, '.txt']);
diary(log_file);

% set random seed
prev_rng = seed_rand(conf.rng_seed);
caffe.set_random_seed(conf.rng_seed);

disp('conf:');
disp(conf);
disp('opts:');
disp(opts);

% init caffe solver
caffe_solver = caffe.Solver(opts.solver_def_file);

% resume mechanism
if isempty(opts.solverstate)
    caffe_solver.net.copy_from(opts.net_file);
    % conf.classes        = opts.imdb_train{1}.classes;
    % try to train/val with images which have maximum size potentially,
    % to validate whether the gpu memory is enough
    check_gpu_memory(conf, caffe_solver, opts.do_val);
else
    % loading solverstate, resume
    caffe_solver.restore(fullfile(cache_dir, ...
        sprintf('%s.solverstate', opts.solverstate)));
    fprintf('\nRestoring from iter %d...\n', caffe_solver.iter()-1);
end

%% making or loading tran/val data for caffe training
mkdir_if_missing('./output/training_test_data/');
% training
if ~isempty(opts.share_data_name)
    train_data_name = [train_data_name_str '_' opts.share_data_name];
else
    train_data_name = [train_data_name_str '_' conf.cache_base_proposal];
end
if exist(sprintf('./output/training_test_data/%s.mat', train_data_name), 'file') ...
        && opts.detect_exist_train_file
    
    ld = load(sprintf('./output/training_test_data/%s.mat', train_data_name));
    image_roidb_train = ld.image_roidb_train;
    bbox_means = ld.bbox_means;
    bbox_stds = ld.bbox_stds;
    fprintf('Loading existant Caffe training data (%s) ...', train_data_name);
    clear ld;
    fprintf(' Done.\n');
else
    fprintf('Preparing Caffe training data (%s) ...\n', train_data_name);
    [image_roidb_train, bbox_means, bbox_stds]...
        = proposal_prepare_image_roidb(conf, opts.imdb_train, opts.roidb_train);
    
    save(sprintf('./output/training_test_data/%s.mat', train_data_name), ...
        'image_roidb_train', 'bbox_means', 'bbox_stds', '-v7.3');
    fprintf(' Done and saved.\n\n');
end
% validation
if ~isempty(opts.share_data_name)
    val_data_name = [opts.imdb_val.name '_' opts.share_data_name];
else
    val_data_name = [opts.imdb_val.name '_' conf.cache_base_proposal];
end
if opts.do_val   
    if exist(sprintf('./output/training_test_data/%s.mat', val_data_name), 'file') ...
            && opts.detect_exist_train_file
        ld = load(sprintf('./output/training_test_data/%s.mat', val_data_name));
        fprintf('Loading existant Caffe validation data (%s) ...', val_data_name);
        image_roidb_val = ld.image_roidb_val;
        shuffled_inds_val = ld.shuffled_inds_val;
        clear ld;
        fprintf(' Done.\n');
    else
        
        fprintf('Preparing Caffe validation data (%s) ...\n', val_data_name);
        [image_roidb_val]...
            = proposal_prepare_image_roidb(conf, opts.imdb_val, opts.roidb_val, bbox_means, bbox_stds);
        % fix validation data
        shuffled_inds_val   = generate_random_minibatch([], image_roidb_val, conf.ims_per_batch);
        shuffled_inds_val   = shuffled_inds_val(randperm(length(shuffled_inds_val), opts.val_iters));
        
        save(sprintf('./output/training_test_data/%s.mat', val_data_name), ...
            'image_roidb_val', 'shuffled_inds_val', '-v7.3');
        fprintf(' Done and saved.\n\n');
    end
end

%% TRAINING
proposal_generate_minibatch_fun = @proposal_generate_minibatch;
% visual_debug_fun                = @proposal_visual_debug;

shuffled_inds = [];
train_results = [];
train_res_total = [];
val_results = [];
iter_ = caffe_solver.iter();
max_iter = caffe_solver.max_iter();
th = tic;

while (iter_ < max_iter)
    
    caffe_solver.net.set_phase('train');
    
    % generate minibatch training data
    [shuffled_inds, sub_db_inds] = generate_random_minibatch(shuffled_inds, ...
        image_roidb_train, conf.ims_per_batch);
    [net_inputs, ~] = proposal_generate_minibatch_fun(conf, ...
        image_roidb_train(sub_db_inds));
    
    % visual_debug_fun(conf, image_roidb_train(sub_db_inds), ...
    %           net_inputs, bbox_means, bbox_stds, conf.classes, scale_inds);
    caffe_solver.net.reshape_as_input(net_inputs);
    
    % one iter SGD update
    caffe_solver.net.set_input_data(net_inputs);
    caffe_solver.step(1);
    rst = caffe_solver.net.get_output();
    rst = check_error(rst, caffe_solver);
    train_results = parse_rst(train_results, rst);
    train_res_total = parse_rst(train_res_total, rst);
    
    if debug && ~mod(iter_, 20)
        fprintf('iter: %d\n', iter_)
        check_loss(rst, caffe_solver, net_inputs);
        fprintf('\n');
    end
    
    % do valdiation per val_interval iterations
    if ~mod(iter_, opts.val_interval)
        if opts.do_val
            val_results = do_validation(conf, caffe_solver, proposal_generate_minibatch_fun, image_roidb_val, shuffled_inds_val);
        end     
        show_state(iter_, train_results, val_results);
        train_results = [];
        diary; diary; % flush diary
    end
    
    % snapshot
    if ~mod(iter_, opts.snapshot_interval)
        snapshot(conf, caffe_solver, bbox_means, bbox_stds, cache_dir, sprintf('iter_%d', iter_));
        save([cache_dir '/' sprintf('loss_%d.mat', iter_)], 'train_res_total', 'val_results');
    end
    % training progress report
    if ~mod(iter_, 100)
        time = toc(th);
        fprintf('iter %d, loss %.4f, time: %.2f min, estTime: %.2f hour\n', ...
            iter_, (10*rst(2).data + rst(3).data), time/60, (time/3600)*(max_iter-iter_)/100);
        th = tic;
    end
    % update iter index
    iter_ = caffe_solver.iter();
end

% % final validation
% if opts.do_val
%     do_validation(conf, caffe_solver, proposal_generate_minibatch_fun, image_roidb_val, shuffled_inds_val);
% end

% final snapshot
snapshot(conf, caffe_solver, bbox_means, bbox_stds, cache_dir, sprintf('iter_%d', iter_));
save_model_path = snapshot(conf, caffe_solver, bbox_means, bbox_stds, cache_dir, 'final');
save([cache_dir '/' sprintf('loss_final_iter_%d.mat', max_iter)], 'train_res_total', 'val_results');

diary off;
caffe.reset_all();
rng(prev_rng);
end

function val_results = do_validation(conf, caffe_solver, ...
    proposal_generate_minibatch_fun, image_roidb_val, shuffled_inds_val)
val_results = [];

caffe_solver.net.set_phase('test');
for i = 1:length(shuffled_inds_val)
    sub_db_inds = shuffled_inds_val{i};
    [net_inputs, ~] = proposal_generate_minibatch_fun(conf, image_roidb_val(sub_db_inds));
    
    % Reshape net's input blobs
    caffe_solver.net.reshape_as_input(net_inputs);
    
    caffe_solver.net.forward(net_inputs);
    rst = caffe_solver.net.get_output();
    rst = check_error(rst, caffe_solver);
    val_results = parse_rst(val_results, rst);
end
end

function [shuffled_inds, sub_inds] = generate_random_minibatch(shuffled_inds, image_roidb_train, ims_per_batch)

% shuffle training data per batch
if isempty(shuffled_inds)
    % make sure each minibatch, only has horizontal images or vertical
    % images, to save gpu memory
    
    hori_image_inds = arrayfun(@(x) x.im_size(2) >= x.im_size(1), image_roidb_train, 'UniformOutput', true);
    vert_image_inds = ~hori_image_inds;
    hori_image_inds = find(hori_image_inds);
    vert_image_inds = find(vert_image_inds);
    
    % random perm
    lim = floor(length(hori_image_inds) / ims_per_batch) * ims_per_batch;
    hori_image_inds = hori_image_inds(randperm(length(hori_image_inds), lim));
    lim = floor(length(vert_image_inds) / ims_per_batch) * ims_per_batch;
    vert_image_inds = vert_image_inds(randperm(length(vert_image_inds), lim));
    
    % combine sample for each ims_per_batch
    hori_image_inds = reshape(hori_image_inds, ims_per_batch, []);
    vert_image_inds = reshape(vert_image_inds, ims_per_batch, []);
    
    shuffled_inds = [hori_image_inds, vert_image_inds];
    shuffled_inds = shuffled_inds(:, randperm(size(shuffled_inds, 2)));
    
    shuffled_inds = num2cell(shuffled_inds, 1);
end

if nargout > 1
    % generate minibatch training data
    sub_inds = shuffled_inds{1};
    assert(length(sub_inds) == ims_per_batch);
    shuffled_inds(1) = [];
end
end

function rst = check_error(rst, caffe_solver)

cls_score = caffe_solver.net.blobs('proposal_cls_score_reshape').get_data();
labels = caffe_solver.net.blobs('labels_reshape').get_data();
labels_weights = caffe_solver.net.blobs('labels_weights_reshape').get_data();

accurate_fg = (cls_score(:, :, 2) > cls_score(:, :, 1)) & (labels == 1);
accurate_bg = (cls_score(:, :, 2) <= cls_score(:, :, 1)) & (labels == 0);
%accurate = accurate_fg | accurate_bg;
accuracy_fg = sum(accurate_fg(:) .* labels_weights(:)) / (sum(labels_weights(labels == 1)) + eps);
accuracy_bg = sum(accurate_bg(:) .* labels_weights(:)) / (sum(labels_weights(labels == 0)) + eps);

rst(end+1) = struct('blob_name', 'accuracy_fg', 'data', accuracy_fg);
rst(end+1) = struct('blob_name', 'accuracy_bg', 'data', accuracy_bg);
end

function check_gpu_memory(conf, caffe_solver, do_val)
%%  try to train/val with images which have maximum size potentially, to validate whether the gpu memory is enough

% generate pseudo training data with max size
im_blob = single(zeros(max(conf.scales), conf.max_size, 3, conf.ims_per_batch));

anchor_num = size(conf.anchors, 1);
output_width = conf.output_width_map.values({size(im_blob, 1)});
output_width = output_width{1};
output_height = conf.output_width_map.values({size(im_blob, 2)});
output_height = output_height{1};
labels_blob = single(zeros(output_width, output_height, anchor_num, conf.ims_per_batch));
labels_weights = labels_blob;
bbox_targets_blob = single(zeros(output_width, output_height, anchor_num*4, conf.ims_per_batch));
bbox_loss_weights_blob = bbox_targets_blob;

net_inputs = {im_blob, labels_blob, labels_weights, bbox_targets_blob, bbox_loss_weights_blob};

% Reshape net's input blobs
caffe_solver.net.reshape_as_input(net_inputs);

% one iter SGD update
caffe_solver.net.set_input_data(net_inputs);
caffe_solver.step(1);

if do_val
    % use the same net with train to save memory
    caffe_solver.net.set_phase('test');
    caffe_solver.net.forward(net_inputs);
    caffe_solver.net.set_phase('train');
end
end

function model_path = snapshot(conf, caffe_solver, bbox_means, bbox_stds, cache_dir, file_name)

% save the intermediate result
anchor_size = size(conf.anchors, 1);
bbox_stds_flatten = repmat(reshape(bbox_stds', [], 1), anchor_size, 1);
bbox_means_flatten = repmat(reshape(bbox_means', [], 1), anchor_size, 1);

% merge bbox_means, bbox_stds into the model
bbox_pred_layer_name = 'proposal_bbox_pred';
weights = caffe_solver.net.params(bbox_pred_layer_name, 1).get_data();
biase = caffe_solver.net.params(bbox_pred_layer_name, 2).get_data();
weights_back = weights;
biase_back = biase;

weights = ...
    bsxfun(@times, weights, permute(bbox_stds_flatten, [2, 3, 4, 1])); % weights = weights * stds;
biase = ...
    biase .* bbox_stds_flatten + bbox_means_flatten; % bias = bias * stds + means;

caffe_solver.net.set_params_data(bbox_pred_layer_name, 1, weights);
caffe_solver.net.set_params_data(bbox_pred_layer_name, 2, biase);

model_path = [fullfile(cache_dir, file_name) '.caffemodel'];
caffe_solver.net.save(model_path);
fprintf('Saved as %s\n', [file_name '.caffemodel']);
solverstate_path = [fullfile(cache_dir, file_name) '.solverstate'];
caffe_solver.snapshot(solverstate_path, model_path);
fprintf('Saved as %s\n', [file_name '.solverstate']);

% restore net to original state
caffe_solver.net.set_params_data(bbox_pred_layer_name, 1, weights_back);
caffe_solver.net.set_params_data(bbox_pred_layer_name, 2, biase_back);
end

function show_state(iter, train_results, val_results)
fprintf('\n------------------------- Iteration %d -------------------------\n', iter);
fprintf('Training : err_fg %.3g, err_bg %.3g, loss (cls %.3g + reg %.3g)\n', ...
    1 - mean(train_results.accuracy_fg.data), 1 - mean(train_results.accuracy_bg.data), ...
    mean(train_results.loss_cls.data), ...
    mean(train_results.loss_bbox.data));
if exist('val_results', 'var') && ~isempty(val_results)
    fprintf('Testing  : err_fg %.3g, err_bg %.3g, loss (cls %.3g + reg %.3g)\n', ...
        1 - mean(val_results.accuracy_fg.data), 1 - mean(val_results.accuracy_bg.data), ...
        mean(val_results.loss_cls.data), ...
        mean(val_results.loss_bbox.data));
end
end

function check_loss(rst, caffe_solver, input_blobs)
%im_blob = input_blobs{1};
labels_blob = input_blobs{2};
label_weights_blob = input_blobs{3};
bbox_targets_blob = input_blobs{4};
bbox_loss_weights_blob = input_blobs{5};

regression_output = caffe_solver.net.blobs('proposal_bbox_pred').get_data();
% smooth l1 loss
regression_delta = abs(regression_output(:) - bbox_targets_blob(:));
regression_delta_l2 = regression_delta < 1;
regression_delta = 0.5 * regression_delta .* regression_delta .* regression_delta_l2 + (regression_delta - 0.5) .* ~regression_delta_l2;
regression_loss = sum(regression_delta.* bbox_loss_weights_blob(:)) / size(regression_output, 1) / size(regression_output, 2);

confidence = caffe_solver.net.blobs('proposal_cls_score_reshape').get_data();
labels = reshape(labels_blob, size(labels_blob, 1), []);
label_weights = reshape(label_weights_blob, size(label_weights_blob, 1), []);
confidence_softmax = bsxfun(@rdivide, exp(confidence), sum(exp(confidence), 3));
confidence_softmax = reshape(confidence_softmax, [], 2);
confidence_loss = confidence_softmax(sub2ind(size(confidence_softmax), 1:size(confidence_softmax, 1), labels(:)' + 1));
confidence_loss = -log(confidence_loss);
confidence_loss = sum(confidence_loss' .* label_weights(:)) / sum(label_weights(:));

results = parse_rst([], rst);
fprintf('C++   : conf %f, reg %f\n', results.loss_cls.data, results.loss_bbox.data);
fprintf('Matlab: conf %f, reg %f\n', confidence_loss, regression_loss);
end

function str = mk_train_str(imdb)
    str = [];
    
    if length(imdb) >= 3
        % it's the imagenet training data
        str = 'ilsvrc14_train';
    else
        for i = 1:length(imdb)
            if i == length(imdb)
                curr_name = imdb.name;
            else
                curr_name = [imdb{i}.name '_'];
            end
            str = [str curr_name];
        end
    end
end