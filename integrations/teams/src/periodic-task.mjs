export function startPeriodicTask({
  operation,
  intervalMilliseconds,
  initialDelayMilliseconds = 0,
  onError = () => {},
}) {
  let timer;
  let activeRun;
  let stopped = false;

  const schedule = (delayMilliseconds) => {
    timer = setTimeout(() => {
      timer = undefined;
      activeRun = Promise.resolve()
        .then(operation)
        .catch(onError)
        .finally(() => {
          activeRun = undefined;
          if (!stopped) schedule(intervalMilliseconds);
        });
    }, delayMilliseconds);
    timer.unref();
  };

  schedule(initialDelayMilliseconds);
  return {
    stop() {
      stopped = true;
      clearTimeout(timer);
      timer = undefined;
    },
    async join() {
      await activeRun;
    },
  };
}
