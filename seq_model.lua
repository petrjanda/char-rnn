local model_utils = require 'util.model_utils'

local SeqModel = { }
SeqModel.__index = SeqModel

function SeqModel.buildProto(modelType, vocab_size, rnn_size, num_layers, dropout)
    local protos = {}

    if modelType == 'lstm' then
        local LSTM = require 'model.LSTM'
        protos.rnn = LSTM.lstm(vocab_size, rnn_size, num_layers, dropout)
    elseif modelType == 'gru' then
        local GRU = require 'model.GRU'
        protos.rnn = GRU.gru(vocab_size, rnn_size, num_layers, dropout)
    elseif modelType == 'rnn' then
        local RNN = require 'model.RNN'
        protos.rnn = RNN.rnn(vocab_size, rnn_size, num_layers, dropout)
    end

    protos.criterion = nn.ClassNLLCriterion()

    return protos
end

-- make a bunch of clones after flattening, as that reallocates memory
local function buildSeq(protos, seq_length)
  local model = {}

  for name, proto in pairs(protos) do
      print('cloning ' .. name)
      model[name] = model_utils.clone_many_times(proto, seq_length)
  end

  model.seq_length = seq_length

  return model
end

local function initState(num_layers, batch_size, rnn_size, modelType)
  local state = {}

  for L = 1, num_layers do
      local h_init = torch.zeros(batch_size, rnn_size)
      h_init = transferGpu(h_init)

      table.insert(state, h_init:clone())
      if modelType == 'lstm' then
          table.insert(state, h_init:clone())
      end
  end

  return state
end




function SeqModel.new(protos, seq_length, num_layers, batch_size, rnn_size, modelType)
  local state = initState(opt.num_layers, opt.batch_size, opt.rnn_size, opt.model)
  local model = buildSeq(protos, seq_length)
  local init_state_global = clone_list(state)
  local o = {}

  setmetatable(o, SeqModel)

  o.model = model
  o.init_state = state
  o.init_state_global = init_state_global

  return o
end

function SeqModel:forward(x, y)
    local rnn_state = {[0] = self.init_state_global}
    local predictions = {} -- softmax outputs

    for t = 1, self.model.seq_length do
        self.model.rnn[t]:training() -- make sure we are in correct mode (this is cheap, sets flag)

        local lst = self.model.rnn[t]:forward{x[t], unpack(rnn_state[t-1])}

        rnn_state[t] = {}
        for i = 1, #self.init_state do 
          table.insert(rnn_state[t], lst[i]) 
        end -- extract the state, without output

        predictions[t] = lst[#lst] -- last element is the prediction
    end

    self.rnn_state = rnn_state

    return predictions
end

function SeqModel:backward(predictions, x, y)
    -- initialize gradient at time t to be zeros (there's no influence from future)
    local drnn_state = {[self.model.seq_length] = clone_list(self.init_state, true)} -- true also zeros the clones

    for t = self.model.seq_length, 1, -1 do
        -- backprop through loss, and softmax/linear
        local doutput_t = self.model.criterion[t]:backward(predictions[t], y[t])
        table.insert(drnn_state[t], doutput_t)
        local dlst = self.model.rnn[t]:backward({x[t], unpack(self.rnn_state[t-1])}, drnn_state[t])
        drnn_state[t-1] = {}
        for k,v in pairs(dlst) do
            if k > 1 then -- k == 1 is gradient on x, which we dont need
                -- note we do k-1 because first item is dembeddings, and then follow the 
                -- derivatives of the state, starting at index 2. I know...
                drnn_state[t-1][k-1] = v
            end
        end
    end

    -- transfer final state to initial state (BPTT)
    self.init_state_global = self.rnn_state[#self.rnn_state] -- NOTE: I don't think this needs to be a clone, right?
end

function SeqModel:loss(predictions, y)
    local loss = 0

    for t = 1, self.model.seq_length do
        loss = loss + self.model.criterion[t]:forward(predictions[t], y[t])
    end

    return loss / self.model.seq_length
end

-- evaluate the loss over an entire split
function SeqModel:eval(ds, split_index)
    print('evaluating loss over split index ' .. split_index)
    local n = ds.split_sizes[split_index]

    ds:reset_batch_pointer(split_index) -- move batch iteration pointer for this split to front
    local loss = 0
    local rnn_state = {[0] = self.init_state}
    
    for i = 1,n do -- iterate over batches in the split
        -- fetch a batch
        local x, y = ds:next_batch(split_index)
        x,y = prepro(x,y)

        -- forward pass
        for t=1,opt.seq_length do
            self.model.rnn[t]:evaluate() -- for dropout proper functioning
            local lst = self.model.rnn[t]:forward{x[t], unpack(rnn_state[t-1])}
            rnn_state[t] = {}
            for i = 1, #self.init_state do table.insert(rnn_state[t], lst[i]) end
            prediction = lst[#lst] 
            loss = loss + self.model.criterion[t]:forward(prediction, y[t])
        end
        -- carry over lstm state
        rnn_state[0] = rnn_state[#rnn_state]
        print(i .. '/' .. n .. '...')
    end

    loss = loss / opt.seq_length / n
    return loss
end


return SeqModel
