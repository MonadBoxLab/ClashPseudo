"""Read the application version and increment patch and versionCode after dependency updates."""


def _declaration(text):
    lines = text.splitlines(keepends=True)
    index = next(index for index, line in enumerate(lines) if line.startswith("version:"))
    value = lines[index].split(":", 1)[1].split("#", 1)[0].strip().strip("\"'")
    return lines, index, value


def application_version(root):
    return _declaration((root / "pubspec.yaml").read_text(encoding="utf-8"))[2]


def bump_version(text):
    lines, index, previous = _declaration(text)
    name, code = previous.rsplit("+", 1)
    components = name.split(".")
    components[-1] = str(int(components[-1]) + 1)
    value = ".".join(components) + "+" + str(int(code) + 1)
    lines[index] = lines[index].replace(previous, value, 1)
    return "".join(lines), value
