function net = run_train(imdbName, varargin)
%RUN_TRAIN Train a CNN model on a provided dataset 
%
%   imdbName:: 
%       must be name of a folder under data/
%   `seed`:: 1
%       random seed
%   `batchSize`: 128
%       set to a smaller number on limited memory
%   `numEpochs`: 30 
%       set to a higher value when training from scratch
%   `gpuMode`:: false
%       set to true to compute on GPU
%   `baseModel`:: 'imagenet-vgg-m'
%       set to empty to train from scratch
%   `prefix`:: 'v1'
%       additional experiment identifier
%   `numFetchThreads`::
%       #threads for vl_imreadjpeg
%   `aug`:: 'none'
%       specifies the operations (fliping, perturbation, etc.) used 
%       to get sub-regions
%   `addDropout`:: true
%       whether add dropout layers (to the last two fc layers)
%   `border`:: []
%       used in data augmentation
%   `multiview`:: false 
%       if true, use shapes (w/ multiple views) instead of images as
%       instances 
%   `viewpoolLoc` :: 'fc7'
%       location of the viewpool layer, only used when multiview is true
%   `learningRate`:: [0.001*ones(1, 10) 0.0001*ones(1, 10) 0.00001*ones(1,10)]
%       learning rate
%   `momentum`:: 0.9
%       learning momentum
% 
opts.seed = 1 ;
opts.batchSize = 128 ;
opts.numEpochs = 30;
opts.gpuMode = false;
opts.baseModel = 'imagenet-vgg-m';
opts.prefix = 'v1' ;
opts.numFetchThreads = 0 ;
opts.aug = 'none';
opts.addDropout = true;
opts.border = [];
opts.multiview = false;
opts.viewpoolLoc = 'fc7';
opts.learningRate = [0.001*ones(1, 10) 0.0001*ones(1, 10) 0.00001*ones(1,10)];
opts.momentum = 0.9;
[opts, varargin] = vl_argparse(opts, varargin) ;

if ~isempty(opts.baseModel), 
    opts.expDir = sprintf('%s-finetuned-%s', opts.baseModel, imdbName); 
else
    opts.expDir = imdbName; 
end
opts.expDir = fullfile('data', opts.prefix, ...
    sprintf('%s-seed-%02d', opts.expDir, opts.seed));
[opts, varargin] = vl_argparse(opts,varargin) ;

if length(opts.border) == 1, opts.border = [opts.border opts.border]; end

if ~exist(opts.expDir, 'dir'), vl_xmkdir(opts.expDir) ; end

% use gpu if requested and possible
if opts.gpuMode,
    if gpuDeviceCount()==0,
        fprintf('No supported gpu detected! ');
        reply = input('Continue w/ cpu mode? Y/N [Y]:','s');
        if ~isempty(reply) && reply~='Y',
            return;
        end
        opts.gpuMode = false;
    else
        gpuDevice(1);
    end
end

% -------------------------------------------------------------------------
%                                                                 Get imdb
% -------------------------------------------------------------------------
imdb = get_imdb(imdbName);
if isfield(imdb.meta,'invert'), 
    opts.invert = imdb.meta.invert;
else
    opts.invert = false;
end
if opts.multiview, 
    nShapes = length(unique(imdb.images.sid));
    opts.nViews = length(imdb.images.id)/nShapes;
end

% -------------------------------------------------------------------------
%                                                    Network initialization
% -------------------------------------------------------------------------

net = initializeNetwork(opts.baseModel, imdb.meta.classes) ;
if ~isempty(opts.border), 
    net.normalization.border = opts.border; 
end

% Initialize average image
if isempty(net.normalization.averageImage), 
    % compute the average image
    averageImagePath = fullfile(opts.expDir, 'average.mat') ;
    if exist(averageImagePath, 'file')
      load(averageImagePath, 'averageImage') ;
    else
      train = find(imdb.images.set == 1) ;
      bs = 256 ;
      fn = getBatchWrapper(net.normalization, 'numThreads',...
          opts.numFetchThreads,'augmentation', opts.aug);
      for t=1:bs:numel(train)
        batch_time = tic ;
        batch = train(t:min(t+bs-1, numel(train))) ;
        fprintf('Computing average image: processing batch starting with image %d ...', batch(1)) ;
        temp = fn(imdb, batch) ;
        im{t} = mean(temp, 4) ;
        batch_time = toc(batch_time) ;
        fprintf(' %.2f s (%.1f images/s)\n', batch_time, numel(batch)/ batch_time) ;
      end
      averageImage = mean(cat(4, im{:}),4) ;
      save(averageImagePath, 'averageImage') ;
    end

    net.normalization.averageImage = averageImage ;
    clear averageImage im temp ;
end

% Add dropout layers
if opts.addDropout, 
    dropoutLayer = struct('type', 'dropout', 'rate', 0.5, 'name','dropout') ;
    net.layers = horzcat(net.layers(1:end-4), ...
                            dropoutLayer, ...
                            net.layers(end-3:end-2), ...
                            dropoutLayer, ...
                            net.layers(end-1:end)); 
end

% Add viewpool layer if multiview is enabled
if opts.multiview, 
    viewpoolLayer = struct('name', 'viewpool', ...
        'type', 'custom', ...
        'stride', opts.nViews, ...
        'method', 'max', ...
        'forward', @viewpool_fw, ...
        'backward', @viewpool_bw);
    net = modify_net(net, ...
        'mode','add_layer', ...
        'layer',viewpoolLayer, ...
        'loc',opts.viewpoolLoc);
end

% -------------------------------------------------------------------------
%                                               Stochastic gradient descent
% -------------------------------------------------------------------------
trainOpts.batchSize = opts.batchSize ;
trainOpts.useGpu = opts.gpuMode ;
trainOpts.expDir = opts.expDir ;
trainOpts.numEpochs = opts.numEpochs ;
trainOpts.multiview = opts.multiview;
trainOpts.learningRate = opts.learningRate ;
trainOpts.momentum = opts.momentum;
trainOpts.continue = true ;
trainOpts.prefetch = false ;
trainOpts.conserveMemory = true;

fn = getBatchWrapper(net.normalization,'numThreads',opts.numFetchThreads, ...
    'augmentation', opts.aug, 'invert', opts.invert);

[net,info] = cnn_train(net, imdb, fn, trainOpts) ;

% Save model
net = vl_simplenn_move(net, 'cpu');
net = saveNetwork(fullfile(opts.expDir, 'final-model.mat'), net);

% -------------------------------------------------------------------------
function net = saveNetwork(fileName, net)
% -------------------------------------------------------------------------
layers = net.layers;

% Replace the last layer with softmax
layers{end}.type = 'softmax';
layers{end}.name = 'prob';

% Remove fields corresponding to training parameters
ignoreFields = {'filtersMomentum', ...
                'biasesMomentum',...
                'filtersLearningRate',...
                'biasesLearningRate',...
                'filtersWeightDecay',...
                'biasesWeightDecay',...
                'class'};
for i = 1:length(layers),
    layers{i} = rmfield(layers{i}, ignoreFields(isfield(layers{i}, ignoreFields)));
end

% Remove dropout layers
removeIndices = cellfun(@(x)(strcmp(x.type, 'dropout')), layers);
layers = layers(~removeIndices);

% Remove viewpool layers
% removeIndices = cellfun(@(x)(strcmp(x.name, 'viewpool')), layers);
% layers = layers(~removeIndices);

net.layers = layers;

save(fileName, '-struct', 'net');


% -------------------------------------------------------------------------
function fn = getBatchWrapper(opts, varargin)
% -------------------------------------------------------------------------
fn = @(imdb,batch) getBatch(imdb,batch,opts,varargin{:}) ;

% -------------------------------------------------------------------------
function [im,labels] = getBatch(imdb, batch, opts, varargin)
% -------------------------------------------------------------------------
images = strcat([imdb.imageDir '/'], imdb.images.name(batch)) ;
[im, idxs] = get_image_batch(images, opts, ...
    'prefetch', nargout == 0, ...
    varargin{:}); 
labels = imdb.images.class(batch(idxs)) ;

% -------------------------------------------------------------------------
function net = initializeNetwork(baseModel, classNames)
% -------------------------------------------------------------------------
scal = 1 ;
init_bias = 0.1;
numClass = length(classNames);

if ~isempty(baseModel), 
    netFilePath = fullfile('data','models', [baseModel '.mat']);
    % download model if not found
    if ~exist(netFilePath,'file'),
        fprintf('Downloading model (%s) ...', baseModel) ;
        vl_xmkdir(fullfile('data','models')) ;
        urlwrite(fullfile('http://www.vlfeat.org/matconvnet/models', ...
            [baseModel '.mat']), netFilePath) ;
        fprintf(' done!\n');
    end
    net = load(netFilePath); % Load model if specified
    
    fprintf('Initializing from model: %s\n', baseModel);
    % Replace the last but one layer with random weights
    widthPenultimate = size(net.layers{end-1}.filters,3); 
    net.layers{end-1} = struct('name','fc8', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(1,1,widthPenultimate,numClass,'single'), ...
                           'biases', zeros(1, numClass, 'single'), ...
                           'stride', 1, ...
                           'pad', 0, ...
                           'filtersLearningRate', 10, ...
                           'biasesLearningRate', 20, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0);
    
    % Last layer is softmaxloss (switch to softmax for prediction)
    net.layers{end} = struct('type', 'softmaxloss', 'name', 'loss') ;

    % Rename classes
    net.classes.name = classNames;
    net.classes.description = classNames;

    % fix border size
    % if max(net.normalization.imageSize(1:2)) < 256, 
    %     net.normalization.border = 256 - net.normalization.imageSize(1:2) ;
    % end
    return;
end

% Else initial model randomly
net.layers = {} ;

% Block 1
net.layers{end+1} = struct('name', 'conv1', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(11, 11, 3, 96, 'single'), ...
                           'biases', zeros(1, 96, 'single'), ...
                           'stride', 4, ...
                           'pad', 0, ...
                           'filtersLearningRate', 1, ...
                           'biasesLearningRate', 2, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0) ;
net.layers{end+1} = struct('type', 'relu') ;
net.layers{end+1} = struct('type', 'pool', ...
                           'method', 'max', ...
                           'pool', [3 3], ...
                           'stride', 2, ...
                           'pad', 0) ;
net.layers{end+1} = struct('type', 'normalize', ...
                           'param', [5 1 0.0001/5 0.75]) ;

% Block 2
net.layers{end+1} = struct('name', 'conv2', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(5, 5, 48, 256, 'single'), ...
                           'biases', init_bias*ones(1, 256, 'single'), ...
                           'stride', 1, ...
                           'pad', 2, ...
                           'filtersLearningRate', 1, ...
                           'biasesLearningRate', 2, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0) ;
net.layers{end+1} = struct('type', 'relu') ;
net.layers{end+1} = struct('type', 'pool', ...
                           'method', 'max', ...
                           'pool', [3 3], ...
                           'stride', 2, ...
                           'pad', 0) ;
net.layers{end+1} = struct('type', 'normalize', ...
                           'param', [5 1 0.0001/5 0.75]) ;

% Block 3
net.layers{end+1} = struct('name', 'conv3', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(3,3,256,384,'single'), ...
                           'biases', init_bias*ones(1,384,'single'), ...
                           'stride', 1, ...
                           'pad', 1, ...
                           'filtersLearningRate', 1, ...
                           'biasesLearningRate', 2, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0) ;
net.layers{end+1} = struct('type', 'relu') ;

% Block 4
net.layers{end+1} = struct('name', 'conv4', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(3,3,192,384,'single'), ...
                           'biases', init_bias*ones(1,384,'single'), ...
                           'stride', 1, ...
                           'pad', 1, ...
                           'filtersLearningRate', 1, ...
                           'biasesLearningRate', 2, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0) ;
net.layers{end+1} = struct('type', 'relu') ;

% Block 5
net.layers{end+1} = struct('name', 'conv5', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(3,3,192,256,'single'), ...
                           'biases', init_bias*ones(1,256,'single'), ...
                           'stride', 1, ...
                           'pad', 1, ...
                           'filtersLearningRate', 1, ...
                           'biasesLearningRate', 2, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0) ;
net.layers{end+1} = struct('type', 'relu') ;
net.layers{end+1} = struct('type', 'pool', ...
                           'method', 'max', ...
                           'pool', [3 3], ...
                           'stride', 2, ...
                           'pad', 0) ;

% Block 6
net.layers{end+1} = struct('name', 'fc6', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(6,6,256,4096,'single'),...
                           'biases', init_bias*ones(1,4096,'single'), ...
                           'stride', 1, ...
                           'pad', 0, ...
                           'filtersLearningRate', 1, ...
                           'biasesLearningRate', 2, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0) ;
net.layers{end+1} = struct('type', 'relu') ;
net.layers{end+1} = struct('type', 'dropout', ...
                           'rate', 0.5) ;

% Block 7
net.layers{end+1} = struct('name', 'fc7', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(1,1,4096,4096,'single'),...
                           'biases', init_bias*ones(1,4096,'single'), ...
                           'stride', 1, ...
                           'pad', 0, ...
                           'filtersLearningRate', 1, ...
                           'biasesLearningRate', 2, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0) ;
net.layers{end+1} = struct('type', 'relu') ;
net.layers{end+1} = struct('type', 'dropout', ...
                           'rate', 0.5) ;

% Block 8
net.layers{end+1} = struct('name', 'fc8', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(1,1,4096,numClass,'single'), ...
                           'biases', zeros(1, numClass, 'single'), ...
                           'stride', 1, ...
                           'pad', 0, ...
                           'filtersLearningRate', 1, ...
                           'biasesLearningRate', 2, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0) ;

% Block 9
net.layers{end+1} = struct('type', 'softmaxloss') ;

% Other details
net.normalization.imageSize = [224, 224, 3] ;
net.normalization.interpolation = 'bicubic' ;
net.normalization.border = 256 - net.normalization.imageSize(1:2) ;
net.normalization.averageImage = [] ;
net.normalization.keepAspect = true ;

% -------------------------------------------------------------------------
function res_ip1 = viewpool_fw(layer, res_i, res_ip1)
% -------------------------------------------------------------------------
[sz1, sz2, sz3, sz4] = size(res_i.x);
if mod(sz4,layer.stride)~=0, 
    error('all shapes should have same number of views');
end
if strcmp(layer.method, 'avg'), 
    res_ip1.x = permute(...
        mean(reshape(res_i.x,[sz1 sz2 sz3 layer.stride sz4/layer.stride]), 4), ...
        [1,2,3,5,4]);
elseif strcmp(layer.method, 'max'), 
    res_ip1.x = permute(...
        max(reshape(res_i.x,[sz1 sz2 sz3 layer.stride sz4/layer.stride]), [], 4), ...
        [1,2,3,5,4]);
else
    error('Unknown viewpool method: %s', layer.method);
end

% -------------------------------------------------------------------------
function res_i = viewpool_bw(layer, res_i, res_ip1)
% -------------------------------------------------------------------------
[sz1, sz2, sz3, sz4] = size(res_ip1.dzdx);
if strcmp(layer.method, 'avg'), 
    res_i.dzdx = ...
        reshape(repmat(reshape(res_ip1.dzdx / layer.stride, ...
                       [sz1 sz2 sz3 1 sz4]), ...
                [1 1 1 layer.stride 1]),...
        [sz1 sz2 sz3 layer.stride*sz4]);
elseif strcmp(layer.method, 'max'), 
    [~,I] = max(reshape(permute(res_i.x,[4 1 2 3]), ...
                [layer.stride, sz4*sz1*sz2*sz3]),[],1);
    Ind = zeros(layer.stride,sz4*sz1*sz2*sz3, 'single');
    Ind(sub2ind(size(Ind),I,1:length(I))) = 1;
    Ind = permute(reshape(Ind,[layer.stride*sz4,sz1,sz2,sz3]),[2 3 4 1]);
    res_i.dzdx = ...
        reshape(repmat(reshape(res_ip1.dzdx, ...
                       [sz1 sz2 sz3 1 sz4]), ...
                [1 1 1 layer.stride 1]),...
        [sz1 sz2 sz3 layer.stride*sz4]) .* Ind;
else
    error('Unknown viewpool method: %s', layer.method);
end

