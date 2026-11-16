/*
 * AFL driver for calcurse's non-interactive query mode over one data file.
 *
 *   calcurse_<mode> <input>      mode (compile-time MODE_*) = apts | todo | conf
 *
 * The input is read from the path given on the command line (Mayhem's smoke test requires the target
 * to open it) and copied to the matching file of a scratch data/config directory, then the real
 * parse_args() runs `calcurse --read-only -D dir -C dir -Q --from 01/01/2000 --days 1500`, which loads
 * the files (calcurse exit()s on malformed ones, which is why this is a file-input target and not
 * libFuzzer) and prints the todo list and every item in the date range.
 */
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include <fcntl.h>
#include <ftw.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int parse_args(int, char **);

#if defined(MODE_APTS)
#define INPUT_NAME "apts"
#elif defined(MODE_TODO)
#define INPUT_NAME "todo"
#elif defined(MODE_CONF)
#define INPUT_NAME "conf"
#else
#error "define MODE_APTS, MODE_TODO or MODE_CONF"
#endif

static int rm_cb(const char *path, const struct stat *sb, int type, struct FTW *ftw)
{
	(void)sb;
	(void)type;
	(void)ftw;
	return remove(path);
}

static char dir[PATH_MAX];

static void cleanup_dir(void)
{
	if (*dir)
		nftw(dir, rm_cb, 8, FTW_DEPTH | FTW_PHYS);
	*dir = '\0';
}

/* Runs from the sanitizers' Die() path, where atexit handlers do not run. */
extern void __sanitizer_set_death_callback(void (*)(void)) __attribute__((weak));

static int copy_file(const char *src, const char *dst)
{
	char buf[65536];
	ssize_t n;
	int in = open(src, O_RDONLY), out;

	if (in < 0)
		return -1;
	out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (out < 0) {
		close(in);
		return -1;
	}
	while ((n = read(in, buf, sizeof buf)) > 0)
		if (write(out, buf, (size_t)n) != n) {
			n = -1;
			break;
		}
	close(in);
	close(out);
	return n < 0 ? -1 : 0;
}

static void touch(const char *dir, const char *name)
{
	char path[PATH_MAX];
	FILE *f;

	snprintf(path, sizeof path, "%s/%s", dir, name);
	f = fopen(path, "w");
	if (f)
		fclose(f);
}

int main(int argc, char **argv)
{
	char link[PATH_MAX];
	const char *tmp = getenv("TMPDIR");
	char *args[] = { "calcurse", "--read-only", "-D", dir, "-C", dir, "-Q",
			 "--from", "01/01/2000", "--days", "1500", NULL };
	int rc;

	if (argc < 2)
		return 2;
	snprintf(dir, sizeof dir, "%s/calcurse-XXXXXX", tmp && *tmp ? tmp : "/tmp");
	if (!mkdtemp(dir)) {
		*dir = '\0';
		return 2;
	}
	atexit(cleanup_dir);
	if (__sanitizer_set_death_callback)
		__sanitizer_set_death_callback(cleanup_dir);
	touch(dir, "apts");
	touch(dir, "todo");
	touch(dir, "conf");
	snprintf(link, sizeof link, "%s/%s", dir, INPUT_NAME);
	if (copy_file(argv[1], link))
		return 2;

	snprintf(link, sizeof link, "%s/stdout", dir);
	if (!freopen(link, "w", stdout))
		return 2;
	rc = parse_args((int)(sizeof args / sizeof *args) - 1, args);

	(void)rc;
	return 0;
}
