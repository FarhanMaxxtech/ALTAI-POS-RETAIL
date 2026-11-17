/// How long a message stays on screen: long enough to read, then it goes away by itself.
/// About 5 s for a short message, up to 12 s for a long one.
Duration readingTime(String text) =>
    Duration(milliseconds: (4000 + 60 * text.length).clamp(5000, 12000));
