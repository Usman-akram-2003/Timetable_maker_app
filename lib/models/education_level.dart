enum EducationLevel {
  intermediate,
  bachelors;

  String get label {
    switch (this) {
      case EducationLevel.intermediate: return 'Intermediate';
      case EducationLevel.bachelors:    return 'Bachelors';
    }
  }
}
