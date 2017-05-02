import std.stdio;
import std.file;
import std.process;
import std.algorithm;
import std.string;
import std.conv;
import std.array;
import std.range;

enum LOGFILE_NAME = "drillease_log.txt";

void main(string[] args)
{
	if (args.length < 3) {
		writeln ("Usage: ", args[0], " [current version] [release version]");
		return;
	}
	string current_version = args[1];
	string release_version = args[2];
	string[] newPoFiles;

	bool checkTranslations = true;
	if (args.length > 3) {
		if (args[3] == "--skip-translations") {
			checkTranslations = false;
		} else {
			writeln("Unknown parameter ", args[3]);
			return;
		}
	}

	writeln ("Releasing ", release_version, " from ", current_version, " ...");

	auto stderr = File(LOGFILE_NAME, "w");
	auto spawn(string[] args) {
		return spawnProcess(args, std.stdio.stdin, stderr, stderr, null,
		                    Config.retainStderr | Config.retainStdout);
	}
	scope(exit){ stderr.close(); }

	if (checkTranslations) {
		// Step 1: Update translations
		writeln ("Updating translations...");
		auto make_update_translations = spawn(["make", "update-translations"]);
		if (wait(make_update_translations) != 0) {
			writeln("make update-translations failed. See log file ", LOGFILE_NAME);
			return;
		}

		// Step 2: Fix up whatever transifex got wrong.
		//         This includes removing trailing whitespace, collapsing mentions of the same translator into one,
		//         fixing wrong order of format specifiers.
		writeln ("Fixing translations...");
		auto po_files = dirEntries("po/", SpanMode.breadth).filter!(f => f.name.endsWith(".po"));
		foreach (file; po_files) {
			writeln ("    Fixing ", file, " ...");
			auto f = File(file);
			string file_buffer;
			auto lines = f.byLine;
			int line_num = 0;

			auto line = lines.front.stripRight();

			pure void appendLine() { file_buffer ~= line ~ "\n"; }
			void next() { appendLine(); lines.popFront(); line = lines.front.stripRight(); }
			while (!lines.empty) {
				line_num ++;

				if (line.startsWith("# Translators:")) {
					//writeln ("Found translators...");
					TranslatorInfo[string] translators;
					lines.popFront();

					for (; !lines.empty; lines.popFront()) {
						line = lines.front;
						if (!line.startsWith("# "))
							break;

						// Strip leading "# "
						line = line[2..$];
						auto parts1 = line.split(",");
						auto name = parts1[0].strip().idup;
						auto year = parts1[1].strip();
						TranslatorInfo *translator;
						if (name in translators) {
							translator = &translators[name];
						} else {
							translators[cast(string)name] = TranslatorInfo();
							translator = &translators[name];
							translator.name = cast(string)name;
						}
						year.split("-").map!(f=>to!int(f)).each!(y => translator.add_year(y));
					}

					// We are done with the translators, collapse them and write them to the buffer
					//writeln ("We have ", translators.keys.length, " translators");
					file_buffer ~= "# Translators:\n";
					foreach (name; translators.keys.sort!("toLower(a) < toLower(b)")) {
						TranslatorInfo info = translators[name];
						file_buffer ~= "# " ~ info.name ~ ", ";
						info.years.sort();
						file_buffer ~= to!string(info.years[0]);
						for (int i = 1; i < info.years.length; i ++)
							file_buffer ~= "-" ~ to!string(info.years[1]);

						file_buffer ~= "\n";
					}
					next();
				} else if (line.startsWith("msgid_plural")) {
					// The format specifiers here need to match the given position OR
					// use the proper notation (e.g. %2$s to get the second argument as a string
					char[] original_format = get_format (cast(string)line[14..$-1]);
					if (original_format.length > 1) {
						next();

						// TODO: Should we handle more than [0] here?
						if (line.startsWith("msgstr[0]") &&
							line != "msgstr[0] \"\"") {
							char[] format = get_format(cast(string)line);

							bool equal = (format == original_format);
							if (format.length != original_format.length) {
								writeln ("Error: File ", file, " contains invalid format specs in line ", line);
								return;
							}

							if (!equal) {
								line = applyFormat(line, original_format, format);
							}
						}
					}
					next();
				} else if (line.startsWith("msgid")) {
					if (line == "msgid \"\"") {
						next();
					}
					auto sourceFormat = getExtendedFormat(line);
					if (sourceFormat.length > 0) {
						// append the current line as well
						next();

						if (!line.startsWith("msgid_plural") &&
						    line != "msgstr \"\"") {
							assert (line.startsWith("msgstr \""));
							line = "msgstr \"" ~ forceFormat(line[8..$ - 1], sourceFormat) ~ "\"";
							next();
						} else {
						  // No next()!
						}
					} else {
					  next();
					}
				} else if (line.startsWith("#. TRANSLATORS: Do NOT translate")) {
					// Check all translated versions and make them match the original one,
					// since this should've never been translated in the first place.

					// Skip to the msgid line
					while (!line.startsWith("msgid ")) {
						next();
					}

					assert(line.startsWith("msgid \""));

					// Strip off 'msgid "' at the beginning and quote at the end
					auto original = cast(char[])line["msgid \"".length..$ - 1].idup;
					//writeln("original icon name: '", original, "'");
					next();
					assert(line.startsWith("msgstr \""));
					// We just always replace this line, no matter what the actual translation was. Simpler.
					line = "msgstr \"" ~ original ~ "\"";
					next();
				}
				else {
				  next();
				}
			}

			std.file.write(file, file_buffer);
		}

		writeln("Updating LINGUAS...");
		// Fetching translations might have pulled new files in, so add them to the LINGUAS
		// file and later to the translations commit
		string linguasText = readText("po/LINGUAS");
		auto pipes = pipeProcess(["git", "ls-files", "po/", "--exclude-standard", "--others"],
		                         Redirect.stdout);
		if (wait(pipes.pid) != 0) {
			writeln("Getting new po files failed. See ", LOGFILE_NAME);
			return;
		}

		foreach(line; pipes.stdout.byLine) {
			if (line.endsWith(".po")) {
				writeln("New po file: ", line);
				newPoFiles ~= line.idup;
				linguasText ~= "\n" ~ line;
			}
		}

		linguasText = linguasText
		              .split("\n")
		              .filter!(l => l.length > 0) // Remove empty lines
		              .map!(l => removePo(l))
		              .array()
		              .sort()
		              .join("\n");
		std.file.write("po/LINGUAS", linguasText);
	}


	writeln("Updating about dialog...");
	{
		File about_dialog = File("ui/about-dialog.ui");
		string file_buffer;

		foreach (line; about_dialog.byLine) {
			if (line.strip.startsWith("<property name=\"version\">"))
				file_buffer ~= line.idup.replace(current_version, release_version) ~ "\n";
			else
				file_buffer ~= line.idup ~ "\n";
		}
		std.file.write(about_dialog.name, file_buffer);
	}

	writeln("Updating README.md...");
	{
		File readme_file = File("README.md");
		string file_buffer;

		foreach (line; readme_file.byLine) {
			if (line.startsWith("# Corebird")) {
				if (line.stripRight.endsWith(current_version))
					file_buffer ~= line.idup.replace(current_version, release_version) ~ "\n";
				else
					file_buffer ~= line.stripRight() ~ " " ~ release_version ~ "\n";
			} else if (line.startsWith("This is the readme")) {
				// Disclaimer about the development version. Skip.
			} else
				file_buffer ~= line.idup ~ "\n";
		}
		std.file.write(readme_file.name, file_buffer);
	}

 	writeln("Updating configure.ac...");
	{
		File readme_file = File("configure.ac");
		string file_buffer;

		foreach (line; readme_file.byLine) {
			if (line.startsWith("AC_INIT"))
				file_buffer ~= line.idup.replace(current_version, release_version) ~ "\n";
			else
				file_buffer ~= line.idup ~ "\n";
		}
		std.file.write(readme_file.name, file_buffer);
	}


	writeln ("Running make distcheck...");
	auto distcheck = spawn(["make", "distcheck"]);
	if (wait(distcheck) != 0) {
		writeln ("make distcheck failed. See ", LOGFILE_NAME);
		return;
	}

	if (checkTranslations) {
		writeln ("Committing po changes...");
		if (newPoFiles.length > 0) {
			foreach (poFile; newPoFiles) {
				auto pid = spawnProcess(["git", "add", poFile]);
				if (wait(pid) != 0) {
					writeln("Failed to git add ", poFile, ". See ", LOGFILE_NAME);
					return;
				}
			}

			auto pid = spawnProcess(["git", "add", "po/LINGUAS"]);
			if (wait(pid) != 0) {
				writeln("Failed to git add LINGUAS file. See ", LOGFILE_NAME);
				return;
			}

		}
		auto po_commit = spawn(["git", "commit", "po/", "-m", "Update translations"]);
		if (wait(po_commit) != 0) {
			writeln ("Commiting po changes failed. See ", LOGFILE_NAME);
			return;
		}
	}

	writeln ("Committing release...");
	auto release_commit = spawn(["git", "commit", "README.md", "configure.ac", "ui/about-dialog.ui",
	                             "-m", "Release " ~ release_version]);
	if (wait(release_commit) != 0) {
		writeln ("Commiting release changes failed. See ", LOGFILE_NAME);
		return;
	}
}

struct TranslatorInfo {
	string name;
	int[] years;

	public void add_year(int year) {
		foreach(y; years) {
			if (y == year)
				return;
		}

		this.years ~= year;
	}
}

pure char[] get_format(const(char)[] s) {
	char[] format;
	for (int i = 0; i < s.length; i ++) {
		if (s[i] == '%' && s[i + 1] != '%' && s[i + 1] != '$') {
			i ++;
			format ~= s[i];
		}
	}

	return format;
}

struct FormatSpecifier {
	char c;
	bool tick = false;
	int pos = -1;
	string toString() {
		char[] r = [c];
		if (pos > -1) r ~= to!string(pos);
		if (tick) r ~= '\'';
		return cast(string)r;
	}
}

pure
FormatSpecifier[] getExtendedFormat(const(char)[] input) {
	FormatSpecifier[] spec;

	for (int i = 0; i < input.length; i ++) {
		if (input[i] == '%') {
			i ++;
			bool tick = false;
			if (input[i] == '\'') {
				tick = true;
				i ++;
			}
			spec ~= FormatSpecifier(input[i], tick, -1);
		}
	}

	return spec;
}
unittest {
	auto spec = getExtendedFormat("foo %'d bar");
	assert(spec.length == 1);
	assert(spec[0].c == 'd');
	assert(spec[0].tick);
}

pure
char[] forceFormat(const(char)[] input, FormatSpecifier[] spec) {
	string back;

	int specPos = 0;

	for (int i = 0; i < input.length; i ++) {
		if (input[i] == '%') {
			auto fspec =  spec[specPos];
			back ~= '%';
			if (fspec.tick)
				back ~= '\'';
			back ~= fspec.c;
			i ++; // Skip next char
			if (input[i] == '\'')
				i ++;
			specPos ++;
		} else {
			back ~= input[i];
		}
	}

	// We went through all of them
	assert(specPos == spec.length);

	return cast(char[]) back;
}
unittest {
	assert(forceFormat("abc %d abc %s",
	       [FormatSpecifier('s', false), FormatSpecifier('d', false)]) == "abc %s abc %d");

	assert(forceFormat("abc %'d abc %'s",
	       [FormatSpecifier('s', true), FormatSpecifier('d', true)]) == "abc %'s abc %'d");
}

pure
char[] applyFormat(const(char)[] input, const char[] sourceFormat, const char[] targetFormat) {
	string back = cast(string)input.idup;
	bool[] taken = new bool[sourceFormat.length];

	for (int i = 0; i < sourceFormat.length; i ++) {
		int orig_index = 0;
		for (int k  = 0; k < sourceFormat.length; k ++) {
			if (!taken[k] && sourceFormat[k] == targetFormat[i]) {
				taken[k] = true;
				orig_index = k;
				break;
			}
		}
		back = back.replace ("%" ~ targetFormat[i], "%" ~ to!string(orig_index + 1) ~ "$" ~ targetFormat[i]);
	}

	return cast(char[])back;
}
unittest {
	assert(applyFormat("foo %d %s", ['s', 'd'], ['d', 's']) == "foo %2$d %1$s");
	assert(applyFormat("foo %d %s", ['d', 's'], ['d', 's']) == "foo %1$d %2$s");
}

pure @nogc
auto removePo(inout(char)[] input) {
	if (input.startsWith("po/")) {
		assert(input.endsWith(".po"));
		return input[3..$ - 3];
	}
	return input;
}
