/* The Looper app opens the ALSA sequencer, ignores the failure, and then calls
 * snd_seq_query_next_client() with a NULL handle -- alsa-lib asserts and the
 * process aborts. There is no /dev/snd/seq in a container, so intercept the
 * call and report "no more clients" instead of tripping the assert. */
#define ENODEV_ 19
int snd_seq_query_next_client(void *seq, void *info) {
  (void)seq; (void)info;
  return -ENODEV_;
}
int snd_seq_query_next_port(void *seq, void *info) {
  (void)seq; (void)info;
  return -ENODEV_;
}
