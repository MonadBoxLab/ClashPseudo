int exercised(bool choice) {
  if (choice) {
    return trueOutcome();
  }
  return falseOutcome();
}

int composite(bool Function() first, bool Function() second) {
  if (first() && second()) {
    return trueOutcome();
  }
  return falseOutcome();
}

int trueOutcome() => 1;
int falseOutcome() => 2;

int neverExecuted() => 99;

int suiteTeardown() => 17;

// coverage 1.16.0 groups these two function entries into one source-line bucket.
// dart format off
int firstSameLine() => 1; int secondSameLine() => 2;
// dart format on
