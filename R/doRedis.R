# Copyright (c) 2010 by Bryan W. Lewis.
#
# This is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as published
# by the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307
# USA

# The environment initialization code is adapted (with minor changes)
# from the doMPI package from Steve Weston.



#' Register the Redis back end for foreach.
#'
#' The doRedis package imlpements a simple but flexible parallel back end
#' for foreach that uses Redis for inter-process communication. The work
#' queue name specifies the base name of a small set of Redis keys that the master
#' and worker processes use to exchange data.
#' 
#' Back-end worker R processes  advertise their availablility for work
#' with the \code{\link{redisWorker}} function.
#' 
#' The doRedis parallel back end tolerates faults among the worker processes and
#' automatically resubmits failed tasks. It is also portable and supports
#' heterogeneous sets of workers, even across operative systems.  The back end
#' supports dynamic pools of worker processes.  New workers may be added to work
#' queues at any time and can be used by running foreach computations.
#'
#' @param queue A work queue name
#' @param host The Redis server host name or IP address
#' @param port The Redis server port number
#' @param password An optional Redis database password
#' @param ...  Optional arguments passed to \code{\link{redisConnect}}
#'
#' @note 
#' All doRedis functions require access to a Redis database server (not included
#' with this package).
#'
#' The doRedis package sets RNG streams across the worker processes using the
#' L'Ecuyer-CMRG method from R's parallel package for reproducible pseudorandom
#' numbers independent of the number of workers or task distribution. See the
#' package vignette for more details and additional options.
#'
#' Avoid using fork-based parallel functions within doRedis expressions.
#' Use of \code{mclapply} and similar functions in the body of a doRedis foreach
#' loop can result in worker faults.
#'
#' @return
#' NULL is invisibly returned.
#'
#' @examples
#' \dontrun{
#' ## The example assumes that a Redis server is running on the local host
#' ## and standard port.
#'
#' ## 1. Open one or more 'worker' R sessions and run:
#' require('doRedis')
#' redisWorker('jobs')
#'
#' ## 2. Open another R session acting as a 'master' and run this simple 
#' ##    sampling approximation of pi:
#' require('doRedis')
#' registerDoRedis('jobs')
#' foreach(j=1:10,.combine=sum,.multicombine=TRUE) \%dopar\%
#'         4*sum((runif(1000000)^2 + runif(1000000)^2)<1)/10000000
#' removeQueue('jobs')
#' }
#'
#' @seealso \code{\link{foreach}}, \code{\link{doRedis-package}}, \code{\link{setChunkSize}}, \code{\link{removeQueue}}
#'
#' @import rredis
#' @import foreach
#' @importFrom parallel nextRNGStream
#' @importFrom iterators nextElem iter
#' @importFrom stats runif
#' @importFrom utils flush.console packageDescription
#' @export
registerDoRedis <- function(queue, host="localhost", port=6379, password, ...)
{
  if(missing(password)) redisConnect(host, port, ...)
  else redisConnect(host,port,password=password, ...)
  assign("queue", queue, envir=.doRedisGlobals)
# Set a queue.live key that signals to workers that this queue is
# valid. We need this because Redis removes the key associated with
# empty lists.
  queueLive <- paste(queue,"live", sep=".")
  if(!redisExists(queueLive)) redisSet(queueLive, "")
  setDoPar(fun=.doRedis, data=list(queue=queue), info=.info)
  invisible()
}

#' Remove a doRedis queue and delete all associated keys from Redis.
#'
#' Removing a doRedis queue cleans up associated keys in the Redis
#' database and signals to workers listening on the queue to terminate.
#' Workers normally terminate after their timeout period after a
#' queue is delete.
#' @param queue The doRedis queue name
#'
#' @note Workers listening for work on more than one queue will only
#' terminate after all their queues have been deleted.
#'
#' @return
#' NULL is invisibly returned.
#'
#' @import rredis
#' @export
removeQueue <- function(queue)
{
  if(redisExists(queue)) redisDelete(queue)
  queueEnv <- redisKeys(pattern=sprintf("%s\\.env.*",queue))
  for (j in queueEnv) redisDelete(j)
  queueOut <- redisKeys(pattern=sprintf("%s\\.out",queue))
  for (j in queueOut) redisDelete(j)
  queueCount <- redisKeys(pattern=sprintf("%s\\.count",queue))
  for (j in queueCount) redisDelete(j)
  queueLive <- redisKeys(pattern=sprintf("%s\\.live",queue))
  for (j in queueLive) redisDelete(j)
  invisible()
}

#' Set the default granularity of distributed tasks.
#'
#' A job is the collection of all tasks in a foreach loop.
#' A task is a collection of loop iterations of at most size \code{chunkSize}.
#' R workers are assigned work by task in blocks of at most
#' \code{chunkSize} loop iterations per task.
#' The default value is one iteration per task.
#' Setting the default chunk size larger for shorter-running jobs can
#' substantially improve performance. Setting this value too high can
#' negatively impact load-balancing across workers, however.
#'
#' @param value Positive integer chunk size setting
#'
#' @note
#' This value is overriden by setting the 'chunkSize' option in the
#' foreach loop (see the examples).
#'
#' @return \code{value} is invisibly returned.
#' @examples
#' \dontrun{
#' setChunkSize(5)
#' foreach(j=1:10) %dopar% j
#'
#' # Same effect as:
#' 
#' foreach(j=1:10,
#'         .options.redis=list(chunkSize=5)) %dopar% j
#' }
#'
#' @export
setChunkSize <- function(value=1)
{
  if(!is.numeric(value)) stop("setChunkSize requires a numeric argument")
  value <- max(round(value), 1)
  assign("chunkSize", value, envir=.doRedisGlobals)
}

#' Set two-level distributed reduction
#'
#' Instruct doRedis to perform the \code{.combine} reduction per task on each
#' worker before returning results. Combined results are then processed through
#' the specified function \code{fun} for two levels of reduction
#' functions. This option only applies when \code{chunkSize} greater than
#' one, and automatically sets \code{.multicombine=FALSE}.
#'
#' This approach can improve performance when the \code{.combine} function is
#' expensive to compute, and when function emits significantly less data than
#' it consumes.
#'
#' @param fun a function of two arguments, set to NULL to disable gather or
#'  leave missing to set the gather function formally identical to the
#'  \code{.combine} function but with an empty environment.
#'
#' @note
#' This value is overriden by setting the 'reduce' option in the
#' foreach loop (see the examples).
#'
#' @return \code{fun} is invisibly returned, or TRUE is returned for
#'  deferred function assignment.
#' @seealso \code{\link{foreach}}, \code{\link{setChunkSize}}
#' @examples
#' \dontrun{
#' setChunkSize(3)
#' setReduce(list)
#' foreach(j=1:10, .combine=c) %dopar% j
#'
#' # Same effect as:
#' 
#' foreach(j=1:10, .combine=c,
#'         .options.redis=list(chunksize=3, reduce=list)) %dopar% j
#' }
#' @export
setReduce <- function(fun=NULL)
{
  if(missing(fun))
  {
# Special case: defer assignment of the function until foreach is called,
# then set it equal to the .combine function.
    return(assign("gather", TRUE, envir=.doRedisGlobals))
  }
# Otherwise explicitly set or clear the function
  if(!(is.function(fun) || is.null(fun))) stop("setGather requires a function or NULL")
  assign("gather", fun, envir=.doRedisGlobals)
}

#' Manually set symbol names to the worker environment export list.
#'
#' The setExport function lets users manually declare symbol names
#' of corresponding objects that should be exported to workers.
#'
#' The \code{foreach} function includes a similar \code{.export} parameter.
#'
#' We provide this supplemental export option for users without direct access
#' to the \code{foreach} function, for example, when \code{foreach} is used
#' inside another package.
#'
#' @param names A character vector of symbol names to export.
#'
#' @return \code{names} is invisibly returned.
#'
#' @examples
#' \dontrun{
#' require("doRedis")
#' registerDoRedis("work queue")
#' startLocalWorkers(n=1, queue="work queue")
#'
#' f <- function() pi
#' 
#' foreach(1) %dopar% eval(call("f"))
#' # Returns the error:
#' # Error in eval(call("f")) : task 1 failed - could not find function "f"
#'
#' # Manuall export the symbol f:
#' setExport("f")
#' foreach(1) %dopar% eval(call("f"))
#' # Ok then.
#' #[[1]]
#' #[1] 3.141593
#' removeQueue("work queue")
#' }
#'
#' @export
setExport <- function(names=c())
{
  assign("export", names, envir=.doRedisGlobals)
}

#' Manually set package names in the worker environment package list.
#'
#' The \code{setPackages} function lets users manually declare packages
#' that R worker processes need to load before running their tasks.
#'
#' The \code{foreach} function includes a similar \code{.packages} parameter.
#'
#' Defines a way to set the foreach \code{.packages} option for users without direct access
#' to the \code{foreach} function, for example, when \code{foreach} is used
#' inside another package.
#'
#' @param packages A character vector of package names.
#'
#' @return The value of \code{packages} is invisibly returned.
#'
#' @export
setPackages <- function(packages=c())
{
  assign("packages", packages, envir=.doRedisGlobals)
}

# An internal foreach function required of backends The number of workers
# reported here is only an estimate.
.info <- function(data, item)
{
    switch(item,
           workers=
             tryCatch(
               {
                 n <- redisGet(
                         paste(.doRedisGlobals$queue,"count",sep="."))
                 if(length(n) == 0) n <- 0
                 else n <- as.numeric(n)
               }, error=function(e) 0),
           name="doRedis",
           version=packageDescription("doRedis", fields="Version"),
           NULL)
}

# internal function, see below for use
.makeDotsEnv <- function(...)
{
  list(...)
  function() NULL
}

.doRedis <- function(obj, expr, envir, data)
{
# ID associates the work with a job environment <queue>.env.<ID>. If
# the workers current job environment does not match job ID, they retrieve
# the new job environment data from queueEnv and run workerInit.
  IDfile <- tempfile("doRedis")
  zz <- file(IDfile,"w")
  close(zz)
  ID <- basename(IDfile)
# The backslash escape charater present in Windows paths causes problems.
  ID <- gsub("\\\\","_",ID)
  queue <- data$queue
  queueEnv <- paste(queue,"env", ID, sep=".")
  queueOut <- paste(queue,"out", ID, sep=".")
  queueStart <- paste(queue,"start",ID, sep=".")
  queueStart <- paste(queueStart, "*", sep="")
  queueAlive <- paste(queue,"alive",ID, sep=".")
  queueAlive <- paste(queueAlive, "*", sep="")

  if (!inherits(obj, "foreach"))
    stop("obj must be a foreach object")

# Manage default parallel RNG, restoring an advanced old RNG state on exit
  .seed <- NULL
  if(exists(".Random.seed", envir=globalenv())) .seed <- get(".Random.seed", envir=globalenv())
  RNG_STATE <- list(kind=RNGkind()[[1]], seed=.seed)
  on.exit(
  {
# Reset RNG
    RNGkind(RNG_STATE$kind)
    assign(".Random.seed",RNG_STATE$seed,envir=globalenv())
    runif(1)
# Clean up the session ID and session environment
    unlink(IDfile)
    if(redisExists(queueEnv)) redisDelete(queueEnv)
    if(redisExists(queueOut)) redisDelete(queueOut)
  })
  RNGkind("L'Ecuyer-CMRG")

  it <- iter(obj)
  argsList <- .to.list(it)

# Distributed reduce
  gather <- NULL
  if(exists("gather", envir=.doRedisGlobals))
    gather <- get("gather", envir=.doRedisGlobals)
  if(!is.null(obj$options$redis$reduce))
    gather <- obj$options$redis$reduce
  if(is.logical(gather) && isTRUE(gather))
  {
    gather <- it$combineInfo$fun
  }

# Setup the parent environment by first attempting to create an environment
# that has '...' defined in it with the appropriate values
  exportenv <- tryCatch({
    qargs <- quote(list(...))
    args <- eval(qargs, envir)
    environment(do.call(.makeDotsEnv, args))
  },
  error=function(e) {
    new.env(parent=emptyenv())
  })
  noexport <- union(obj$noexport, obj$argnames)
  getexports(expr, exportenv, envir, bad=noexport)
  vars <- ls(exportenv)
  if (obj$verbose) {
    if (length(vars) > 0) {
      cat("automatically exporting the following objects",
          "from the local environment:\n")
      cat(" ", paste(vars, collapse=", "), "\n")
    } else {
      cat("no objects are automatically exported\n")
    }
  }
# Compute list of variables to export
  export <- unique(c(obj$export,.doRedisGlobals$export))
  ignore <- intersect(export, vars)
  if (length(ignore) > 0) {
    warning(sprintf("already exporting objects(s): %s",
            paste(ignore, collapse=", ")))
    export <- setdiff(export, ignore)
  }
# Add explicitly exported variables to exportenv
  if (length(export) > 0) {
    if (obj$verbose)
      cat(sprintf("explicitly exporting objects(s): %s\n",
                  paste(export, collapse=", ")))
    for (sym in export) {
      if (!exists(sym, envir, inherits=TRUE))
        stop(sprintf("unable to find variable \"%s\"", sym))
      assign(sym, get(sym, envir, inherits=TRUE),
             pos=exportenv, inherits=FALSE)
    }
  }
# Upload `exportenv` and related data as common job data for the workers
# making sure the data fit in Redis.
  if(object.size(exportenv) > REDIS_MAX_VALUE_SIZE)
  {
    message("The exported environment size is too large.\nConsider breaking up your data across multiple Redis keys.")
    stop("exportenv too big")
  }
  results <- NULL
  ntasks <- length(argsList)

  chunkSize <- 0
  if(exists("chunkSize", envir=.doRedisGlobals))
    chunkSize <- get("chunkSize", envir=.doRedisGlobals)
  if(!is.null(obj$options$redis$chunkSize))
    chunkSize <- obj$options$redis$chunkSize
  chunkSize <- tryCatch(max(chunkSize - 1, 0), error=function(e) 0)

  if(!is.null(gather))
  {
# Modify iterator to include the combine function
    exportCombineInfo = it$combineInfo
    environment(exportCombineInfo$fun) <- emptyenv()
    redisSet(queueEnv, list(expr=expr,
                            exportenv=exportenv,
                            packages=obj$packages,
                            combineInfo=exportCombineInfo))
  } else redisSet(queueEnv, list(expr=expr,
                                 exportenv=exportenv, packages=obj$packages))
# Check for a fault-tolerance check interval (in seconds), do not
# allow it to be less than 3 seconds (see alive.c thread code).
  ftinterval <- 30
  if(!is.null(obj$options$redis$ftinterval))
   {
    tryCatch(
      ftinterval <- obj$options$redis$ftinterval,
      error=function(e) {ftinterval <<- 30; warning(e)}
    )
   }
  ftinterval <- max(ftinterval,3)

# Queue the task(s)
# The task order is encoded in names(argsList).
  nout <- 1
  j <- 1
  done <- c()  # A vector of completed tasks
# To speed this up, we added nonblocking calls to rredis and use them.
  redisSetPipeline(TRUE)
  redisMulti()
  while(j <= ntasks)
  {
    k <- min(j + chunkSize, ntasks)
    block <- argsList[j:k]
    if(!is.null(gather)) names(block) <- rep(nout, k - j + 1)
    else names(block) <- j:k
    redisRPush(queue, list(ID=ID, argsList=block))
    j <- k + 1
    nout <- nout + 1
  }
  redisExec()
  redisGetResponse(all=TRUE)
  redisSetPipeline(FALSE)

# Adjust iterator, accumulator function for distributed accumulation
  if(!is.null(gather))
  {
    cfun <- it$combineInfo$fun
    it$state$numValues <- nout - 1
    it$combineInfo$fun <- gather
    it$state$fun <- gather # this is the only one that matters?
    it$combineInfo$multi.combine <- FALSE
    it$combineInfo$has.init <- FALSE
    it$combineInfo$init <- c()
  }
  accumulator <- makeAccum(it)

# Collect the results and pass through the accumulator
  j <- 1
tryCatch(
{
  while(j < nout)
  {
    results <- redisBRPop(queueOut, timeout=ftinterval)
    if(is.null(results))
    {
      # Check for worker fault and re-submit tasks if required...
      # This detects asymmetry between started and alive processes,
      # resubmitting started tasks whose workers are no longer alive.
      started <- sub(paste(queue, "start", "", sep="."), "", redisKeys(queueStart))
      alive <- sub(paste(queue, "alive", "",sep="."), "", redisKeys(queueAlive))
      fault <- setdiff(started,alive)
      if(length(fault) > 0) {
        # One or more worker faults have occurred. Re-sumbit the work.
        fault <- paste(queue, "start", fault, sep=".")
        fjobs <- redisMGet(fault)
        redisDelete(fault)
        for (resub in fjobs) {
          block <- argsList[unlist(resub)]
          names(block) <- unlist(resub)
          warning(sprintf("Worker fault: resubmitting job(s) %s", names(block)), immediate.=TRUE)
          redisRPush(queue, list(ID=ID, argsList=block))
        }
      }
      # Check for lost results
      qlen <- as.integer(redisLLen(queue))
      if(qlen == 0 && length(started) == 0)
      {
        for(resub in setdiff(1:nout, done)) {
          block <- argsList[resub]
          names(block) <- resub
          warning(sprintf("Worker fault: resubmitting task %s", names(block)), immediate.=TRUE)
          redisRPush(queue, list(ID=ID, argsList=block))
        }
      }
    }
    else
    {
      j <- j + 1
      n <- as.numeric(names(results[[1]]))
      done <- c(done, n)
      tryCatch(accumulator(results[[1]], n),
        error=function(e) {
          cat("error calling combine function:\n", file=stderr())
          print(e)
      })
    }
  }
}, interrupt=function(e) flushQueue(queue,ID), error=function(e) flushQueue(queue,ID))


# check for errors
  errorValue <- getErrorValue(it)
  errorIndex <- getErrorIndex(it)

# throw an error or return the combined results
  if (identical(obj$errorHandling, "stop") && !is.null(errorValue)) {
    msg <- sprintf("task %d failed - \"%s\"", errorIndex,
                   conditionMessage(errorValue))
    stop(simpleError(msg, call=expr))
  } else {
    getResult(it)
  }
}

# internal function to deal with user interrupt
# clean up redis work queue, removing all tasks in the job defined by ID
flushQueue <- function(queue, ID)
{
  startkeys <- redisKeys(pattern=sprintf("%s.start*",queue))
  redisSetPipeline(TRUE)
  redisMulti()
  redisLRange(queue,0L,1000000000L)  # retrieve everything on the work queue
  tryCatch(redisDelete(queue), error=function(e) NULL) # delete the queue
  if(!is.null(startkeys)) tryCatch(redisDelete(startkeys), error=function(e) NULL)
  redisExec()
  tasks <- redisGetResponse(all=TRUE)
  redisSetPipeline(FALSE)
# Re-queue jobs not matching ID (these are other jobs submitted to the queue).
# First we need to locate the IDs, if any, in the result.
  idx <- grep("ID", tasks)
  if(length(idx) == 0) return()
  lapply(tasks[[idx]][[1]], function(j)
  {
    if(j$ID != ID) redisRPush(queue, list(ID=j$ID, argsList=j$argsList))
  })
}

# Convert the iterator to a list
.to.list <- function(x)
{
  seed <- .Random.seed
  n <- 64
  a <- vector("list", length=n)
  i <- 0
  tryCatch({
    repeat {
      if (i >= n) {
        n <- 2 * n
        length(a) <- n
      }
      seed <- nextRNGStream(seed)
      rs <- list(.Random.seed=seed)
      a[[i + 1]] <- c(nextElem(x), rs)
      i <- i + 1
    }
  },
  error=function(e) {
    if (!identical(conditionMessage(e), "StopIteration"))
      stop(e)
  })
  length(a) <- i
  a
}
