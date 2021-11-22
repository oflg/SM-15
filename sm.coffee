###
# SM.js
# (c) 2014 Kazuaki Tanida
# This software can be freely distributed under the MIT license.
###


class @SM
  constructor: ->
    @requestedFI = 10 #默认遗忘指数
    @intervalBase = 24 * 60 * 60 * 1000 #初始间隔
    @q = []  # items sorted by dueDate #卡片列表
    @fi_g = new FI_G @ #FI-G graph，遗忘指数-评分图。评分与遗忘指数 - FI-G图将预期遗忘指数与重复时的评分联系起来。你需要了解SuperMemo算法SM-15来理解这个图形。你可以想象，遗忘曲线图可能在其纵轴上使用平均评分而不是保留率。如果你将这个评分与遗忘指数相关联，你就会得出FI-G图。这个图形被用来计算一个估计的遗忘指数，而这个指数又被用来对评分进行归一化处理（对于延迟的或高级的重复），并估计项目的A因子的新值。评分是用公式计算出来的。评分=Exp(A*FI+B)，即e^{A*FI+B}其中A和B是对复读期间收集的原始数据进行指数回归的参数。
    @forgettingCurves = new ForgettingCurves @ #遗忘曲线。遗忘曲线。RF矩阵的各个条目是根据每个条目的近似遗忘曲线来计算的。每条遗忘曲线都对应着不同的重复次数和不同的A因子值（或在第一次重复的情况下的记忆断层）。RF矩阵条目的值对应于遗忘曲线通过从所要求的遗忘指数得出的知识保留点的时间点。例如，对于一个新项目的第一次重复，如果遗忘指数等于10%，四天后，遗忘曲线所表示的知识保留率下降到90%以下的数值，RF[1,1]的值就被当作4。这意味着所有进入学习过程的项目将在四天后被重复学习（假设矩阵OF和RF在第一列的第一行没有差异）。这满足了SuperMemo的主要前提，即重复应该发生在遗忘概率等于100%减去以百分比表示的遗忘指数的时刻。
    @rfm = new RFM @ #RF matrix，RF矩阵是retention factor保留度的矩阵。矩阵的列与项目易度相对应，矩阵的行与记忆稳定性相对应。RF矩阵在SuperMemo 6中被引入，并被用于所有版本的算法，直到算法SM-15。在后来的算法中，它的等价物是对应于检索性等于0.9的稳定性增加矩阵的片断。
    @ofm = new OFM @ #OF matrix，OF矩阵是optimum factor 最佳记忆度的矩阵。从RF矩阵推导出OF矩阵。OF矩阵的最佳值是通过一连串的近似程序从RF矩阵中得出的，RF矩阵的定义与OF矩阵相同，不同的是它的值取自被优化的学生的真实学习过程。最初，OF和RF矩阵是相同的；然而，RF矩阵的条目在每次重复时都会被修改，OF矩阵的新值是通过使用近似程序从RF矩阵计算出来的。这有效地产生了OF矩阵作为RF矩阵的平滑形式。简单地说，RF矩阵在任何给定的时刻都对应于从学习过程中得到的最佳拟合值；然而，每个条目被认为是其自身的最佳拟合条目，即从其他RF条目的值中抽象出来。同时，OF矩阵被认为是一个最佳匹配的整体。换句话说，在重复过程中，RF矩阵是逐条计算的，而OF矩阵是RF矩阵的一个平滑副本。
    
  _findIndexToInsert: (item, r = [0...@q.length]) =>
    return 0 if r.length == 0
    v = item.dueDate
    i = Math.floor (r.length / 2) #向下取整、
    if r.length == 1
      return if v < @q[r[i]].dueDate then r[i] else r[i] + 1
    return @_findIndexToInsert item, (if v < @q[r[i]].dueDate then r[...i] else r[i..])
    
  addItem: (value) =>
    item = new Item @, value
    @q.splice @_findIndexToInsert(item), 0, item

  nextItem: (isAdvanceable = false) =>
    return null if 0 == @q.length
    return @q[0] if isAdvanceable or @q[0].dueDate < new Date()
    return null

  answer: (grade, item, now = new Date()) =>
    @_update grade, item, now
    @discard item
    @q.splice @_findIndexToInsert(item), 0, item

  _update: (grade, item, now = new Date()) =>
    if item.repetition >= 0
      @forgettingCurves.registerPoint grade, item, now
      @ofm.update()
      @fi_g.update grade, item, now
    item.answer grade, now

  discard: (item) =>
    index = @q.indexOf item
    @q.splice index, 1 if index >= 0

  data: =>
    requestedFI: @requestedFI
    intervalBase: @intervalBase
    q: (item.data() for item in @q)
    fi_g: @fi_g.data()
    forgettingCurves: @forgettingCurves.data()
    version: 1
      
  @load: (data) =>
    sm = new @()
    sm.requestedFI = data.requestedFI
    sm.intervalBase = data.intervalBase
    sm.q = (Item.load sm, d for d in data.q)
    sm.fi_g = FI_G.load sm, data.fi_g
    sm.forgettingCurves = ForgettingCurves.load sm, data.forgettingCurves
    sm.ofm.update()
    return sm
    

RANGE_AF = 20 #绝对易度范围
RANGE_REPETITION = 20 #重复范围

MIN_AF = 1.2 #最小绝对易度
NOTCH_AF = 0.3  #绝对易度档位
MAX_AF = MIN_AF + NOTCH_AF * (RANGE_AF - 1)#最大绝对易度

MAX_GRADE = 5 #最大评分
THRESHOLD_RECALL = 3 #表示记起的评分阈值


class Item
  MAX_AFS_COUNT = 30 #最大绝对易度记录数量
    
  constructor: (@sm, @value) ->
    @lapse = 0 #记忆偏差次数
    @repetition = -1 #重复次数
    @of = 1 #optimum factor 最佳记忆度
    @optimumInterval = @sm.intervalBase #最佳间隔
    @dueDate = new Date 0 #到期时间
    @_afs = [] #绝对易度记录
 
  interval: (now = new Date())=>
    return @sm.intervalBase if not @previousDate?
    return now - @previousDate

  #used interval ratio factor 间隔改变率
  uf: (now = new Date()) => 
    return @interval(now) / (@optimumInterval / @of)

  # A-Factor
  af: (value = undefined) => 
    return @_af if not value?
    a = Math.round((value - MIN_AF) / NOTCH_AF) # a值=(输入值-最小绝对易度)/绝对易度档位，再四舍五入
    @_af = Math.max MIN_AF, Math.min MAX_AF, MIN_AF + a * NOTCH_AF # 绝对易度=max(最小绝对易度,min(最大绝对易度,最小绝对易度+a值*绝对易度档位))
    
  afIndex: =>
    afs = (MIN_AF + i * NOTCH_AF for i in [0...RANGE_AF])
    return [0...RANGE_AF].reduce (a, b) => if Math.abs(@af() - afs[a]) < Math.abs(@af() - afs[b]) then a else b

  # 1. Obtain optimum interval
  # This algorithm employs a slightly different approach from the original description of SM-15.
  # It derives the optimum interval from the acutual interval and O-Factor instead of the previously calculated interval and O-Factor.
  # This approach may make it possible to conduct advanced repetition and delayed repetition without employing a complicated way.
  _I: (now = new Date()) =>
    of_ = @sm.ofm.of(@repetition, if @repetition == 0 then @lapse else @afIndex())
    @of = Math.max 1, (of_ - 1) * (@interval(now) / @optimumInterval) + 1
    @optimumInterval = Math.round @optimumInterval * @of
    
    @previousDate = now
    @dueDate = new Date now.getTime() + @optimumInterval

  # 9. 11. Update A-Factor
  _updateAF: (grade, now = new Date()) =>
    estimatedFI = Math.max 1, @sm.fi_g.fi grade #estimatedFI，预估遗忘指数
    correctedUF = @uf(now) * (@sm.requestedFI / estimatedFI) #correctedUF，矫正遗忘指数
    estimatedAF = 
      if @repetition > 0
        @sm.ofm.af @repetition, correctedUF
      else
        Math.max MIN_AF, Math.min MAX_AF, correctedUF
    
    @_afs.push estimatedAF
    @_afs = @_afs[(Math.max 0, @_afs.length - MAX_AFS_COUNT)..-1]
    @af (sum(@_afs.map (a, i) -> a * (i+1)) / sum([1..@_afs.length]))  # weighted average

  answer: (grade, now = new Date()) =>
    @_updateAF grade, now if @repetition >= 0
    if grade >= THRESHOLD_RECALL
      @repetition++ if @repetition < (RANGE_REPETITION - 1)
      @_I now
    else
      @lapse++ if @lapse < (RANGE_AF - 1)
      @optimumInterval = @sm.intervalBase
      @previousDate = null  # set interval() to @sm.intervalBase
      @dueDate = now
      @repetition = -1

  data: =>
    value: @value
    repetition: @repetition
    lapse: @lapse
    of: @of
    optimumInterval: @optimumInterval
    dueDate: @dueDate
    previousDate: @previousDate
    _afs: @_afs

  @load: (sm, data) =>
    item = new @ sm
    item[k] = v for k, v of data
    item.dueDate = new Date item.dueDate
    item.previousDate = new Date item.previousDate if item.previousDate?
    return item


class FI_G
  MAX_POINTS_COUNT = 5000
  GRADE_OFFSET = 1
    
  constructor: (@sm, @points = undefined) ->
    if not @points?
      @points = []
      @_registerPoint p[0], p[1] for p in [[0, MAX_GRADE], [100, 0]]
  
  _registerPoint: (fi, g) =>
    @points.push [fi, g + GRADE_OFFSET]
    @points = @points[(Math.max 0, @points.length - MAX_POINTS_COUNT)..-1]
      
  #10. Update regression of FI-G graph
  update: (grade, item, now = new Date()) =>
    预期遗忘指数
    expectedFI = =>
      return (item.uf(now) / item.of) * @sm.requestedFI  # assuming linear forgetting curve for simplicity
      ### A way to get the expected forgetting index using a forgetting curve
      curve = @sm.forgettingCurves.curves[item.repetition][item.afIndex()]
      uf = curve.uf (100 - @sm.requestedFI)
      return 100 - curve.retention (item.uf() / uf)
      ###
      
    @_registerPoint expectedFI(), grade
    @_graph = null

  # Estimated forgetting index 预估遗忘指数
  fi: (grade) =>
    @_graph ?= exponentialRegression @points
    return Math.max 0, Math.min 100, @_graph?.x (grade + GRADE_OFFSET)

  grade: (fi) =>
    @_graph ?= exponentialRegression @points
    return (@_graph?.y fi) - GRADE_OFFSET

  data: =>
    points: @points

  @load: (sm, data) =>
    return new @ sm, data.points

class ForgettingCurves
  FORGOTTEN = 1
  REMEMBERED = 100 + FORGOTTEN
    
  constructor: (@sm, points = undefined) ->
    @curves =
      for r in [0...RANGE_REPETITION]
        for a in [0...RANGE_AF]
          partialPoints = 
            if points?
              points[r][a]
            else  # initial points that define an initial curve
              p = 
                if r > 0
                  ([MIN_AF + NOTCH_AF * i, Math.min REMEMBERED, Math.exp((-(r+1) / 200) * (i - a * Math.sqrt(2 / (r+1)))) * (REMEMBERED - @sm.requestedFI)] for i in [0..20])
                else
                  ([MIN_AF + NOTCH_AF * i, Math.min REMEMBERED, Math.exp((-1 / (10 + 1*(a+1))) * (i - Math.pow(a, 0.6))) * (REMEMBERED - @sm.requestedFI)] for i in [0..20])
              [[0, REMEMBERED]].concat p
          new ForgettingCurve partialPoints

  registerPoint: (grade, item, now = new Date()) =>
    afIndex = if item.repetition > 0 then item.afIndex() else item.lapse
    @curves[item.repetition][afIndex].registerPoint grade, item.uf now

  data: =>
    points: ((@curves[r][a].points for a in [0...RANGE_AF]) for r in [0...RANGE_REPETITION])

  @load: (sm, data) =>
    return new @ sm, data.points

  class ForgettingCurve
    MAX_POINTS_COUNT = 500

    constructor: (@points) ->
      
    registerPoint: (grade, uf) =>
      isRemembered = grade >= THRESHOLD_RECALL
      @points.push [uf, if isRemembered then REMEMBERED else FORGOTTEN]
      @points = @points[(Math.max 0, @points.length - MAX_POINTS_COUNT)..-1]
      @_curve = null
      
    retention: (uf) =>
      @_curve ?= exponentialRegression @points
      return (Math.max FORGOTTEN, Math.min @_curve.y(uf), REMEMBERED) - FORGOTTEN

    uf: (retention) =>
      @_curve ?= exponentialRegression @points
      return Math.max 0, @_curve.x (retention + FORGOTTEN)
      

# R-Factor Matrix
class RFM
  constructor: (@sm) ->
    
  rf: (repetition, afIndex) =>
    return @sm.forgettingCurves.curves[repetition][afIndex].uf (100 - @sm.requestedFI)

    
# Optimum Factor Matrix
class OFM
  INITIAL_REP_VALUE = 1
    
  afFromIndex = (a) -> a * NOTCH_AF + MIN_AF
  repFromIndex = (r) -> r + INITIAL_REP_VALUE  # repetition value used for regression
  
  constructor: (@sm) ->
    @update()

  # 8.
  update: =>
    # D-factor (a/p^b): the basis of decline of O-Factors, the decay constant of power approximation along RF matrix columns
    dfs = (fixedPointPowerLawRegression(([repFromIndex(r), @sm.rfm.rf(r, a)] for r in [1...RANGE_REPETITION]), [repFromIndex(1), afFromIndex(a)]).b for a in [0...RANGE_AF])
    dfs = (afFromIndex(a) / Math.pow(2, dfs[a]) for a in [0...RANGE_AF])
    decay = linearRegression ([a, dfs[a]] for a in [0...RANGE_AF])
    
    @_ofm = (a) ->
      ###
        O-Factor (given repetition, A-Factor and D-Factor) would be modeled by power law
        y = a(x/p)^b, a = A-Factor, b = D-Factor, x = repetition, p = 2 #second repetition number
          = (a/p^b)x^b
      ###
      af = afFromIndex a
      b = Math.log(af / decay.y(a)) / Math.log(repFromIndex 1)
      model = powerLawModel (af / Math.pow(repFromIndex(1), b)), b
      return {
        y: (r) -> model.y repFromIndex r
        x: (y) -> (model.x y) - INITIAL_REP_VALUE
      }

    ofm0 = exponentialRegression ([a, @sm.rfm.rf(0, a)] for a in [0...RANGE_AF])
    @_ofm0 = (a) -> ofm0.y a

  of: (repetition, afIndex) =>
    return (if repetition == 0 then @_ofm0? afIndex else @_ofm?(afIndex).y repetition)

  # obtain corresponding A-Factor (column) from n (row) and value
  af: (repetition, of_) =>
    return afFromIndex [0...RANGE_AF].reduce (a, b) => if Math.abs(@of(repetition, a) - of_) < Math.abs(@of(repetition, b) - of_) then a else b


sum = (values) ->
  return values.reduce (a, b) -> a + b

mse = (y, points) ->
  return sum(Math.pow(y(points[i][0]) - points[i][1], 2) for i in [0...points.length]) / points.length

# reference: http://mathworld.wolfram.com/LeastSquaresFittingExponential.html 指数回归分析
exponentialRegression = (points) ->
  n = points.length
  X = (p[0] for p in points)
  Y = (p[1] for p in points)
  logY = Y.map Math.log
  sqX = X.map (v) -> v * v
  
  sumLogY = sum logY
  sumSqX = sum sqX
  sumX = sum X
  sumXLogY = sum(X[i] * logY[i] for i in [0...n])
  sqSumX = sumX * sumX

  a = (sumLogY * sumSqX - sumX * sumXLogY) / (n * sumSqX - sqSumX)
  b = (n * sumXLogY - sumX * sumLogY) / (n * sumSqX - sqSumX)

  _y = (x) -> Math.exp(a) * Math.exp(b * x)
  return {
    y: _y
    x: (y) -> (-a + Math.log(y)) / b
    a: Math.exp a
    b: b
    mse: -> mse _y, points
  }

# Least squares method 线性回归分析
linearRegression = (points) ->
  n = points.length
  X = (p[0] for p in points)
  Y = (p[1] for p in points)
  sqX = X.map (v) -> v * v

  sumY = sum Y
  sumSqX = sum sqX
  sumX = sum X
  sumXY = sum (X[i] * Y[i] for i in [0...n])
  sqSumX = sumX * sumX

  a = (sumY * sumSqX - sumX * sumXY) / (n * sumSqX - sqSumX)
  b = (n * sumXY - sumX * sumY) / (n * sumSqX - sqSumX)
  
  return {
    y: (x) -> a + b * x
    x: (y) -> (y - a) / b
    a: a
    b: b
  }

#幂次模型
powerLawModel = (a, b) ->
  y: (x) -> a * Math.pow(x, b)
  x: (y) -> Math.pow (y / a), (1 / b)
  a: a
  b: b

#幂次回归分析
# reference: http://mathworld.wolfram.com/LeastSquaresFittingPowerLaw.html
powerLawRegression = (points) ->
  n = points.length
  X = (p[0] for p in points)
  Y = (p[1] for p in points)
  logX = X.map Math.log
  logY = Y.map Math.log

  sumLogXLogY = sum (logX[i] * logY[i] for i in [0...n])
  sumLogX = sum logX
  sumLogY = sum logY
  sumSqLogX = sum logX.map (v) -> v * v
  sqSumLogX = sumLogX * sumLogX
  
  b = (n * sumLogXLogY - sumLogX * sumLogY) / (n * sumSqLogX - sqSumLogX)
  a = (sumLogY - b * sumLogX) / n

  model = powerLawModel Math.exp(a), b
  model.mse = -> mse _y, points
  return model

#修改幂次回归分析
fixedPointPowerLawRegression = (points, fixedPoint) ->
  ###
    given fixed point: (p, q)
    the model would be: y = q(x/p)^b
    minimize its residual: ln(y) = b * ln(x/p) + ln(q)
      y_i' = b * x_i'
        x_i' = ln(x_i/p)
        y_i' = ln(y_i) - ln(q)
  ###
  n = points.length
  p = fixedPoint[0]
  q = fixedPoint[1]
  logQ = Math.log q
  X = (Math.log (point[0] / p) for point in points)
  Y = (Math.log(point[1]) - logQ for point in points)
  b = linearRegressionThroughOrigin([X[i], Y[i]] for i in [0...n]).b  

  model = powerLawModel (q / Math.pow p, b), b
  return model
  
#过原点的线性回归分析
linearRegressionThroughOrigin = (points) ->
  n = points.length
  X = (p[0] for p in points)
  Y = (p[1] for p in points)

  sumXY = sum (X[i] * Y[i] for i in [0...n])
  sumSqX = sum X.map (v) -> v * v
  
  b = sumXY / sumSqX

  return {
    y: (x) -> b * x
    x: (y) -> y / b
    b: b
  }

module?.exports = {
  SM: @SM
  _test: {
    exponentialRegression: exponentialRegression
    linearRegression: linearRegression
    powerLawRegression: powerLawRegression
    fixedPointPowerLawRegression: fixedPointPowerLawRegression
    linearRegressionThroughOrigin: linearRegressionThroughOrigin
  }
}


# Run a simple flash card app on CLI when this module is directly run
main = =>
  fs = require 'fs'
    
  console.log '(a)add, (n)next, (N)next advanceably, (s)save, (l)load, (e)exit'
  mode = ['entrance']
  data = null
  sm = new @SM()
  
  gotoEnterance = ->
    mode = ['entrance']
    data = null
    process.stdout.write 'sm> '
    
  process.stdin.on 'readable', =>
    chunk = process.stdin.read()
    input = chunk?.toString().trim()
    switch mode[0]
      when 'entrance'
        switch input
          when 'a', 'add' then mode = ['add']
          when 'n', 'next' then mode = ['next']
          when 'N', 'Next' then mode = ['next', '_adv']
          when 's', 'save' then mode = ['save']
          when 'l', 'load' then mode = ['load']
          when 'e', 'exit' then mode = ['exit']
          when 'eval' then mode = ['eval']
          when 'list' then mode = ['list']
          else gotoEnterance()
            
    switch mode[0]
      when 'add'
        switch mode[1]
          when undefined
            data = {front: null, back: null}
            console.log 'Enter the front of the new card:'
            mode[1] = 'front'
          when 'front'
            data.front = input
            console.log 'Enter the back of the new card:'
            mode[1] = 'back'
          when 'back'
            data.back = input
            sm.addItem data
            gotoEnterance()
            
      when 'next'
        switch mode[1]
          when undefined, '_adv'
            data = sm.nextItem(mode[1] == '_adv')
            if not data?
              console.log "There is no card#{if sm.q.length > 0 then ' that can be shown now. The next card is due at \"' + sm.q[0].dueDate.toLocaleString() + '\".' else '.'}"
              gotoEnterance()
            else
              console.log "How much do you remember [#{data.value.front}]:"
              mode[1] = 'review'
          when 'review'
            g = (parseInt input)
            if 0 <= g <= 5
              sm.answer g, data
              console.log "The answer was [#{data.value.back}]."
              gotoEnterance()
            else if input == 'D'
              sm.discard data
              gotoEnterance()
            else
              console.log 'The value should be from \'0\' (bad) to \'5\' (good). Otherwise \'D\' to discard:'

      when 'save'
        if not mode[1]?
          console.log 'enter file name to save configuration. (default name is [data.json]):'
          mode[1] = true
        else
          input = 'data.json' if input == ''
          fs.writeFileSync input, JSON.stringify sm.data()
          gotoEnterance()

      when 'load'
        if not mode[1]?
          console.log 'enter file name to load configuration. (default name is [data.json]):'
          mode[1] = true
        else
          input = 'data.json' if input == ''
          buf = fs.readFileSync input
          data = JSON.parse buf.toString()
          sm = @SM.load data
          gotoEnterance()
              
      when 'exit'
        if not mode[1]?
          process.stdin.pause()
          mode[1] = 'paused'
          
      when 'eval'
        if not mode[1]?
          mode[1] = true
        else
          console.log eval input
          gotoEnterance()

      when 'list'
        console.log (JSON.stringify item.data() for item in sm.q)
        gotoEnterance()

try  
  main() if module? and require?.main == module
catch error
  console.error "An error occured: #{error}"
