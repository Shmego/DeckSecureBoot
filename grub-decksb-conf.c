/* decksb-conf.c - Parse SteamOS bootconf and expose slot selection. */
/*
 *  GRUB  --  GRand Unified Bootloader
 *  Copyright (C) 2026
 *
 *  GRUB is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  GRUB is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with GRUB.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <grub/dl.h>
#include <grub/command.h>
#include <grub/env.h>
#include <grub/file.h>
#include <grub/misc.h>
#include <grub/mm.h>
#include <grub/types.h>

GRUB_MOD_LICENSE ("GPLv3+");

#define DECKSB_CONF_MAX_SIZE 8192

struct decksb_conf_info
{
  grub_uint64_t boot_requested_at;
  grub_uint64_t boot_time;
  grub_uint64_t boot_count;
  int reboot_self;
  int valid;
};

static const char *
skip_ws (const char *p)
{
  while (p && *p && grub_isspace (*p))
    p++;
  return p;
}

static void
parse_conf_line (struct decksb_conf_info *info, const char *line)
{
  const char *value;

  if (!line || !*line)
    return;

  if (grub_strncmp (line, "boot-requested-at:", 18) == 0)
    {
      value = skip_ws (line + 18);
      info->boot_requested_at = grub_strtoul (value, 0, 10);
      return;
    }

  if (grub_strncmp (line, "boot-time:", 10) == 0)
    {
      value = skip_ws (line + 10);
      info->boot_time = grub_strtoul (value, 0, 10);
      return;
    }

  if (grub_strncmp (line, "boot-count:", 11) == 0)
    {
      value = skip_ws (line + 11);
      info->boot_count = grub_strtoul (value, 0, 10);
      return;
    }

  if (grub_strncmp (line, "comment:", 8) == 0)
    {
      value = skip_ws (line + 8);
      if (value && grub_strstr (value, "reboot (self)"))
        info->reboot_self = 1;
      return;
    }
}

static void
read_conf_file (const char *path, struct decksb_conf_info *info)
{
  grub_file_t file;
  grub_off_t size;
  grub_ssize_t read_len;
  char *buf;
  char *line;
  char *next;

  file = grub_file_open (path, GRUB_FILE_TYPE_CONFIG);
  if (!file)
    {
      grub_errno = 0;
      return;
    }

  info->valid = 1;
  size = grub_file_size (file);
  if (size == GRUB_FILE_SIZE_UNKNOWN || size <= 0 || size > DECKSB_CONF_MAX_SIZE)
    size = DECKSB_CONF_MAX_SIZE;

  buf = grub_malloc (size + 1);
  if (!buf)
    {
      grub_file_close (file);
      return;
    }

  read_len = grub_file_read (file, buf, size);
  grub_file_close (file);
  if (read_len <= 0)
    {
      grub_free (buf);
      return;
    }

  buf[read_len] = '\0';
  line = buf;
  while (line && *line)
    {
      next = grub_strchr (line, '\n');
      if (next)
        {
          *next = '\0';
          next++;
        }
      if (line[0] && line[grub_strlen (line) - 1] == '\r')
        line[grub_strlen (line) - 1] = '\0';
      parse_conf_line (info, line);
      line = next;
    }

  grub_free (buf);
}

static char
pick_latest (grub_uint64_t a, grub_uint64_t b)
{
  if (a > b)
    return 'A';
  if (b > a)
    return 'B';
  return 0;
}

static char
pick_slot (const struct decksb_conf_info *a, const struct decksb_conf_info *b, const char **reason)
{
  char slot = 0;

  if (a->valid && !b->valid)
    {
      if (reason)
        *reason = "only-A";
      return 'A';
    }
  if (b->valid && !a->valid)
    {
      if (reason)
        *reason = "only-B";
      return 'B';
    }
  if (!a->valid && !b->valid)
    return 0;

  if (a->reboot_self || b->reboot_self)
    {
      if (a->reboot_self && !b->reboot_self)
        {
          if (reason)
            *reason = "reboot-self";
          return 'A';
        }
      if (b->reboot_self && !a->reboot_self)
        {
          if (reason)
            *reason = "reboot-self";
          return 'B';
        }
      slot = pick_latest (a->boot_requested_at, b->boot_requested_at);
      if (!slot)
        slot = pick_latest (a->boot_time, b->boot_time);
      if (!slot)
        slot = pick_latest (a->boot_count, b->boot_count);
      if (reason)
        *reason = "reboot-self";
      return slot;
    }

  if (a->boot_requested_at || b->boot_requested_at)
    {
      slot = pick_latest (a->boot_requested_at, b->boot_requested_at);
      if (slot && reason)
        *reason = "boot-requested-at";
      return slot;
    }

  if (a->boot_time || b->boot_time)
    {
      slot = pick_latest (a->boot_time, b->boot_time);
      if (slot && reason)
        *reason = "boot-time";
      return slot;
    }

  if (a->boot_count || b->boot_count)
    {
      slot = pick_latest (a->boot_count, b->boot_count);
      if (slot && reason)
        *reason = "boot-count";
      return slot;
    }

  return 0;
}

static void
set_u64_env (const char *name, grub_uint64_t value)
{
  char *buf;

  buf = grub_xasprintf ("%llu", (unsigned long long) value);
  if (!buf)
    return;
  grub_env_set (name, buf);
  grub_free (buf);
}

static grub_err_t
grub_cmd_decksb_conf (grub_command_t cmd __attribute__ ((unused)),
                      int argc, char **args)
{
  struct decksb_conf_info info_a;
  struct decksb_conf_info info_b;
  char *path_a;
  char *path_b;
  const char *reason = 0;
  char slot = 0;

  if (argc < 1)
    return grub_error (GRUB_ERR_BAD_ARGUMENT, "usage: decksb_conf <conf_dir>");

  grub_memset (&info_a, 0, sizeof (info_a));
  grub_memset (&info_b, 0, sizeof (info_b));

  if (args[0][0] && args[0][grub_strlen (args[0]) - 1] == '/')
    {
      path_a = grub_xasprintf ("%sA.conf", args[0]);
      path_b = grub_xasprintf ("%sB.conf", args[0]);
    }
  else
    {
      path_a = grub_xasprintf ("%s/A.conf", args[0]);
      path_b = grub_xasprintf ("%s/B.conf", args[0]);
    }

  if (!path_a || !path_b)
    {
      grub_free (path_a);
      grub_free (path_b);
      return grub_errno;
    }

  read_conf_file (path_a, &info_a);
  read_conf_file (path_b, &info_b);

  grub_free (path_a);
  grub_free (path_b);

  slot = pick_slot (&info_a, &info_b, &reason);
  if (slot)
    {
      char slot_buf[2];
      slot_buf[0] = slot;
      slot_buf[1] = '\0';
      grub_env_set ("decksb_slot", slot_buf);
    }
  if (reason)
    grub_env_set ("decksb_reason", reason);

  if (info_a.valid)
    {
      set_u64_env ("decksb_a_requested_at", info_a.boot_requested_at);
      set_u64_env ("decksb_a_boot_time", info_a.boot_time);
      set_u64_env ("decksb_a_boot_count", info_a.boot_count);
    }
  if (info_b.valid)
    {
      set_u64_env ("decksb_b_requested_at", info_b.boot_requested_at);
      set_u64_env ("decksb_b_boot_time", info_b.boot_time);
      set_u64_env ("decksb_b_boot_count", info_b.boot_count);
    }

  return 0;
}

static grub_command_t cmd;

GRUB_MOD_INIT(decksb_conf)
{
  cmd = grub_register_command ("decksb_conf", grub_cmd_decksb_conf,
                               N_("CONF_DIR"),
                               N_("Parse SteamOS bootconf and set decksb_slot."));
}

GRUB_MOD_FINI(decksb_conf)
{
  grub_unregister_command (cmd);
}
