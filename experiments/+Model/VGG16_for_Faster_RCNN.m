function model = VGG16_for_Faster_RCNN(solver_name_rpn, test_file_rpn, ...
    solver_name_fast_rcnn, test_file_fast_rcnn)
% VGG 16layers (only finetuned from conv3_1)
% for ilsvrc dataset!

if nargin < 3
  solver_name_fast_rcnn = ''; test_file_fast_rcnn = '';
end
model.mean_image = fullfile(pwd, 'models', 'pre_trained_models', 'vgg_16layers', 'mean_image');
model.pre_trained_net_file = fullfile(pwd, 'models', 'pre_trained_models', 'vgg_16layers', 'vgg16.caffemodel');
% Stride in input image pixels at the last conv layer
model.feat_stride = 16;

%% stage 1 rpn, inited from pre-trained network
model.stage1_rpn.solver_def_file = fullfile(pwd, 'models', 'rpn_prototxts', ...
    'vgg_16layers_conv3_1', sprintf('%s.prototxt', solver_name_rpn));

model.stage1_rpn.test_net_def_file = fullfile(pwd, 'models', 'rpn_prototxts', ...
    'vgg_16layers_conv3_1', sprintf('%s.prototxt', test_file_rpn));
model.stage1_rpn.init_net_file = model.pre_trained_net_file;

% rpn test setting
model.stage1_rpn.nms.note                       = 'default';
model.stage1_rpn.nms.per_nms_topN               = -1;
model.stage1_rpn.nms.nms_overlap_thres       	= 0.7;
model.stage1_rpn.nms.after_nms_topN         	= 2000;
% default for multi-thres nms
model.stage1_rpn.nms.nms_iou_thrs   = [0.95, 0.90, 0.85, 0.80, 0.75, 0.65, 0.60, 0.55];
model.stage1_rpn.nms.max_per_image  = [2000, 1000,  400,  200,  100,   40,   20,   10];
% % set 1, 84.12
% model.stage1_rpn.nms.nms_iou_thrs   = [0.90, 0.80, 0.75, 0.70, 0.65, 0.60, 0.55, 0.50];
% model.stage1_rpn.nms.max_per_image  = [2000, 1000,  500,  400,  300,   200,   100,   50];
% % set 2, 68.55
% model.stage1_rpn.nms.nms_iou_thrs   = [0.90, 0.80,  0.75, 0.70, 0.65,  0.60, 0.55,  0.50];
% model.stage1_rpn.nms.max_per_image  = [2000, 50,    200,  400,  600,   800,  1000,  100];
% % set 3 and 4 (no minus previous boxes)
% model.stage1_rpn.nms.nms_iou_thrs   = [0.90, 0.80, 0.75, 0.70, 0.65, 0.60, 0.55, 0.50];
% model.stage1_rpn.nms.max_per_image  = [2000, 1000,  500,  500,  500,  500,  500,  300];

%% stage 1 fast rcnn, inited from pre-trained network
model.stage1_fast_rcnn.solver_def_file = fullfile(pwd, 'models', ...
    'fast_rcnn_prototxts', 'vgg_16layers_conv3_1', sprintf('%s.prototxt', solver_name_fast_rcnn));
model.stage1_fast_rcnn.test_net_def_file = fullfile(pwd, 'models', ...
    'fast_rcnn_prototxts', 'vgg_16layers_conv3_1', sprintf('%s.prototxt', test_file_fast_rcnn));
model.stage1_fast_rcnn.init_net_file = model.pre_trained_net_file;

%% stage 2 rpn, only finetune fc layers
model.stage2_rpn.solver_def_file                = fullfile(pwd, 'models', 'rpn_prototxts', 'vgg_16layers_fc6', 'solver_60k80k.prototxt');
model.stage2_rpn.test_net_def_file              = fullfile(pwd, 'models', 'rpn_prototxts', 'vgg_16layers_fc6', 'test.prototxt');

% rpn test setting
model.stage2_rpn.nms.per_nms_topN              	= -1;
model.stage2_rpn.nms.nms_overlap_thres       	= 0.7;
model.stage2_rpn.nms.after_nms_topN           	= 2000;

%% stage 2 fast rcnn, only finetune fc layers
model.stage2_fast_rcnn.solver_def_file          = fullfile(pwd, 'models', 'fast_rcnn_prototxts', 'vgg_16layers_fc6', 'solver_30k40k.prototxt');
model.stage2_fast_rcnn.test_net_def_file        = fullfile(pwd, 'models', 'fast_rcnn_prototxts', 'vgg_16layers_fc6', 'test.prototxt');

%% final test
model.final_test.nms.per_nms_topN              	= 6000; % to speed up nms
model.final_test.nms.nms_overlap_thres       	= 0.7;
model.final_test.nms.after_nms_topN          	= 300;
end
