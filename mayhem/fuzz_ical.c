/* libFuzzer harness: iCalendar import (the code behind `calcurse -i file.ics`). */
#include "calcurse.h"

#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/*
 * ical_read_event/ical_read_todo turn DESCRIPTION/LOCATION/COMMENT into note
 * files via generate_note(), which writes "<path_notes><sha1>". Point the data
 * dir at a private scratch dir under $TMPDIR so notes never land in the cwd,
 * and empty notes/ after each input so no input sees an earlier one's files.
 */
static char scratch_dir[4096];
static char notes_dir[4096 + 8];

static void empty_notes(void)
{
	DIR *d = opendir(notes_dir);
	struct dirent *e;
	char path[sizeof(notes_dir) + 256];

	if (!d)
		return;
	while ((e = readdir(d))) {
		if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
			continue;
		snprintf(path, sizeof(path), "%s/%s", notes_dir, e->d_name);
		unlink(path);
	}
	closedir(d);
}

static void remove_scratch(void)
{
	empty_notes();
	rmdir(notes_dir);
	rmdir(scratch_dir);
}

static void reset_items(void)
{
	apoint_llist_free();
	event_llist_free();
	recur_apoint_llist_free();
	recur_event_llist_free();
	todo_free_list();
	apoint_llist_init();
	event_llist_init();
	recur_apoint_llist_init();
	recur_event_llist_init();
	todo_init_list();
}

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
	(void)argc;
	(void)argv;
	const char *tmp = getenv("TMPDIR");

	if (!tmp || !*tmp)
		tmp = "/tmp";
	snprintf(scratch_dir, sizeof(scratch_dir), "%s/fuzz_ical.XXXXXX", tmp);
	if (!mkdtemp(scratch_dir)) {
		perror("fuzz_ical: mkdtemp");
		abort();
	}
	snprintf(notes_dir, sizeof(notes_dir), "%s/notes", scratch_dir);
	if (mkdir(notes_dir, 0700) != 0) {
		perror("fuzz_ical: mkdir notes");
		abort();
	}
	atexit(remove_scratch);

	vars_init();
	/* Sets path_notes to "<scratch_dir>/notes/" (io_init appends the '/'). */
	io_init(NULL, scratch_dir, scratch_dir);
	reset_items();
	empty_notes();
	return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	unsigned events = 0, apoints = 0, todos = 0, lines = 0, skipped = 0;
	FILE *in, *log_sink;
	char *log_buf = NULL;
	size_t log_len = 0;

	/* fmemopen() requires a non-empty buffer. */
	if (size == 0)
		return -1;
	in = fmemopen((void *)data, size, "r");
	log_sink = open_memstream(&log_buf, &log_len);
	if (!in || !log_sink) {
		if (in)
			fclose(in);
		if (log_sink) {
			fclose(log_sink);
			free(log_buf);
		}
		return 0;
	}

	ical_import_data("fuzz.ics", in, log_sink, &events, &apoints, &todos,
			 &lines, &skipped, NULL, NULL, NULL, NULL, NULL);
	fclose(in);
	fclose(log_sink);
	free(log_buf);

	/* Imported items accumulate in global lists; drop them so each input stands alone. */
	reset_items();
	empty_notes();
	return 0;
}
