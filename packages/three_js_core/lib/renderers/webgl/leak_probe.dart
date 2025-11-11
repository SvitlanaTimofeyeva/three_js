class LeakLog {
  static final i = LeakLog();
  int frames = 0;

  void ping(String tag) {
    // keep it stupidly loud so it’s visible in Xcode/AS
    // ignore: avoid_print
    print('[LEAKCHK:$tag] f=$frames');
  }
}
