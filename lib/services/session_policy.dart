/// When an untouched app signs the user out on its own.
class SessionPolicy {
  SessionPolicy._();

  static const idleLimit = Duration(minutes: 10);

  static const idleMessage =
      'You were signed out after 10 minutes of inactivity.';

  /// Salesmen stay signed in while they are out on their route. Each signed-in
  /// home sets this; until then the safer choice applies.
  static bool signsOutWhenIdle = true;
}
