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
#include <grub/device.h>
#include <grub/disk.h>
#include <grub/env.h>
#include <grub/file.h>
#include <grub/gpt_partition.h>
#include <grub/misc.h>
#include <grub/mm.h>
#include <grub/partition.h>
#include <grub/types.h>

GRUB_MOD_LICENSE ("GPLv3+");

#define DECKSB_CONF_MAX_SIZE 8192
#define DECKSB_PARTSET_MAX_SIZE 8192

struct d_ci
{
  grub_uint64_t boot_requested_at;
  grub_uint64_t boot_time;
  grub_uint64_t boot_count;
  int reboot_self;
  char *mode;
  int valid;
};

struct d_pi
{
  char *rootfs;
  char *efi;
  char *var;
  char *home;
  char *esp;
  int valid;
};

static const char *
skip_ws (const char *p)
{
  while (p && *p && grub_isspace (*p))
    p++;
  return p;
}

static char
d_tol (char c)
{
  if (c >= 'A' && c <= 'Z')
    return (char) (c - 'A' + 'a');
  return c;
}

static int
d_is_w (char c)
{
  if ((c >= '0' && c <= '9')
      || (c >= 'a' && c <= 'z')
      || (c >= 'A' && c <= 'Z')
      || c == '_')
    return 1;
  return 0;
}

static int
d_is_h (char c)
{
  c = d_tol (c);
  return ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'));
}

static int
d_is_mc (char c)
{
  c = d_tol (c);
  if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z'))
    return 1;
  return (c == '-' || c == '_' || c == '.');
}

static int
d_sw_ci (const char *s, const char *prefix)
{
  while (*prefix)
    {
      if (!*s)
        return 0;
      if (d_tol (*s) != d_tol (*prefix))
        return 0;
      s++;
      prefix++;
    }
  return 1;
}

static int
d_has_k (const char *line, const char *key)
{
  grub_size_t i;
  grub_size_t line_len;
  grub_size_t key_len;

  if (!line || !key)
    return 0;

  line_len = grub_strlen (line);
  key_len = grub_strlen (key);
  if (line_len < key_len)
    return 0;

  for (i = 0; i + key_len <= line_len; i++)
    {
      grub_size_t j;
      char prev;
      char next;
      int match = 1;

      for (j = 0; j < key_len; j++)
        {
          if (d_tol (line[i + j]) != key[j])
            {
              match = 0;
              break;
            }
        }
      if (!match)
        continue;

      prev = (i > 0) ? line[i - 1] : '\0';
      next = (i + key_len < line_len) ? line[i + key_len] : '\0';
      if (d_is_w (prev) || d_is_w (next))
        continue;

      return 1;
    }

  return 0;
}

static int
d_uuid_at (const char *p)
{
  grub_size_t i;
  grub_size_t len;

  if (!p)
    return 0;
  len = grub_strlen (p);
  if (len < 36)
    return 0;

  for (i = 0; i < 36; i++)
    {
      if (i == 8 || i == 13 || i == 18 || i == 23)
        {
          if (p[i] != '-')
            return 0;
        }
      else if (!d_is_h (p[i]))
        return 0;
    }

  if (p[36] && (d_is_h (p[36]) || p[36] == '-'))
    return 0;

  return 1;
}

static char *
d_uuid_cp (const char *p)
{
  char *out;
  grub_size_t i;

  if (!d_uuid_at (p))
    return 0;

  out = grub_malloc (37);
  if (!out)
    return 0;

  for (i = 0; i < 36; i++)
    out[i] = d_tol (p[i]);
  out[36] = '\0';
  return out;
}

static char *
d_uuid_ln (const char *line)
{
  const char *p;
  const char *prefix;
  grub_size_t i;
  grub_size_t prefix_len;
  const char *prefixes[] = { "partuuid=", "by-partuuid/", "uuid=" };
  grub_size_t prefix_lens[] = { 9, 12, 5 };
  grub_size_t k;

  if (!line)
    return 0;

  for (k = 0; k < 3; k++)
    {
      prefix = prefixes[k];
      prefix_len = prefix_lens[k];

      p = line;
      while (p && *p)
        {
          while (*p && !d_sw_ci (p, prefix))
            p++;
          if (!*p)
            break;

          p += prefix_len;
          while (*p && !d_is_h (*p))
            p++;
          if (d_uuid_at (p))
            return d_uuid_cp (p);

          if (*p)
            p++;
        }
    }

  for (i = 0; line[i]; i++)
    {
      if (!d_is_h (line[i]))
        continue;
      if (d_uuid_at (&line[i]))
        return d_uuid_cp (&line[i]);
    }

  return 0;
}

static char *
d_mode_ln (const char *line)
{
  const char *needle = "bootconf mode:";
  const char *p;
  const char *start;
  grub_size_t len;
  grub_size_t i;
  char *out;

  if (!line)
    return 0;

  p = line;
  while (*p)
    {
      if (d_sw_ci (p, needle))
        {
          p += 14;
          p = skip_ws (p);
          start = p;
          while (*p && d_is_mc (*p))
            p++;
          len = (grub_size_t) (p - start);
          if (!len)
            return 0;

          out = grub_malloc (len + 1);
          if (!out)
            return 0;
          for (i = 0; i < len; i++)
            out[i] = d_tol (start[i]);
          out[len] = '\0';
          return out;
        }
      p++;
    }

  return 0;
}

static void
parse_conf_line (struct d_ci *info, const char *line)
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
      if (!info->mode && value)
        info->mode = d_mode_ln (value);
      return;
    }
}

static void
read_conf_file (const char *path, struct d_ci *info)
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

static void
parse_partset_line (struct d_pi *info, char *line)
{
  char *comment;
  char *uuid = 0;

  if (!line || !*line)
    return;

  while (*line && grub_isspace (*line))
    line++;
  if (!*line || *line == '#')
    return;

  comment = grub_strchr (line, '#');
  if (comment)
    *comment = '\0';

  if (!info->rootfs && d_has_k (line, "rootfs"))
    {
      uuid = d_uuid_ln (line);
      if (uuid)
        info->rootfs = uuid;
    }
  if (!info->efi && d_has_k (line, "efi"))
    {
      uuid = d_uuid_ln (line);
      if (uuid)
        info->efi = uuid;
    }
  if (!info->var && d_has_k (line, "var"))
    {
      uuid = d_uuid_ln (line);
      if (uuid)
        info->var = uuid;
    }
  if (!info->home && d_has_k (line, "home"))
    {
      uuid = d_uuid_ln (line);
      if (uuid)
        info->home = uuid;
    }
  if (!info->esp && d_has_k (line, "esp"))
    {
      uuid = d_uuid_ln (line);
      if (uuid)
        info->esp = uuid;
    }

  if (info->rootfs || info->efi || info->var || info->home || info->esp)
    info->valid = 1;
}

static void
read_partset_file (const char *path, struct d_pi *info)
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

  size = grub_file_size (file);
  if (size == GRUB_FILE_SIZE_UNKNOWN || size <= 0 || size > DECKSB_PARTSET_MAX_SIZE)
    size = DECKSB_PARTSET_MAX_SIZE;

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
      parse_partset_line (info, line);
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
pick_slot (const struct d_ci *a, const struct d_ci *b, const char **reason)
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

static void
set_or_unset_env (const char *name, const char *value)
{
  if (value && *value)
    grub_env_set (name, value);
  else
    grub_env_unset (name);
}

static void
clr_cf_env (void)
{
  grub_env_unset ("d_sl");
  grub_env_unset ("d_rs");
  grub_env_unset ("d_a_rq");
  grub_env_unset ("d_a_tm");
  grub_env_unset ("d_a_ct");
  grub_env_unset ("d_b_rq");
  grub_env_unset ("d_b_tm");
  grub_env_unset ("d_b_ct");
  grub_env_unset ("d_a_sf");
  grub_env_unset ("d_b_sf");
  grub_env_unset ("d_a_md");
  grub_env_unset ("d_b_md");
}

struct d_ru_ctx
{
  const char *want;
  char *found;
};

static int
d_eq_uuid_ci (const char *a, const char *b)
{
  grub_size_t i;

  if (!a || !b)
    return 0;
  if (!d_uuid_at (a) || !d_uuid_at (b))
    return 0;

  for (i = 0; i < 36; i++)
    {
      if (d_tol (a[i]) != d_tol (b[i]))
        return 0;
    }
  return 1;
}

static int
d_get_part_uuid (grub_device_t dev, char out[37])
{
  struct grub_partition *p;
  grub_disk_t disk;
  struct grub_gpt_partentry entry;
  grub_guid_t guid;

  if (!dev || !dev->disk || !dev->disk->partition || !out)
    return 0;
  if (!dev->disk->partition->partmap
      || grub_strcmp (dev->disk->partition->partmap->name, "gpt") != 0)
    return 0;

  p = dev->disk->partition;
  disk = grub_disk_open (dev->disk->name);
  if (!disk)
    return 0;

  if (grub_disk_read (disk, p->offset, p->index, sizeof (entry), &entry))
    {
      grub_error_push ();
      grub_disk_close (disk);
      grub_error_pop ();
      return 0;
    }
  grub_disk_close (disk);

  guid = entry.guid;
  guid.data1 = grub_le_to_cpu32 (guid.data1);
  guid.data2 = grub_le_to_cpu16 (guid.data2);
  guid.data3 = grub_le_to_cpu16 (guid.data3);
  grub_snprintf (out, 37, "%pG", &guid);
  return 1;
}

static int
d_find_partuuid_iter (const char *name, void *data)
{
  struct d_ru_ctx *ctx = data;
  grub_device_t dev;
  char part_uuid[37];

  if (!ctx || !ctx->want || !name || !name[0])
    return 0;
  if (ctx->found)
    return 1;
  if (!grub_strchr (name, ','))
    return 0;

  dev = grub_device_open (name);
  if (!dev)
    {
      grub_errno = GRUB_ERR_NONE;
      return 0;
    }

  if (d_get_part_uuid (dev, part_uuid) && d_eq_uuid_ci (ctx->want, part_uuid))
    {
      ctx->found = grub_strdup (name);
      grub_device_close (dev);
      return ctx->found ? 1 : 0;
    }

  grub_device_close (dev);
  grub_errno = GRUB_ERR_NONE;
  return 0;
}

static void
clr_ps_env (void)
{
  grub_env_unset ("d_ps_ok");
  grub_env_unset ("d_ps_src");
  grub_env_unset ("d_ps_rf");
  grub_env_unset ("d_ps_ef");
  grub_env_unset ("d_ps_vr");
  grub_env_unset ("d_ps_hm");
  grub_env_unset ("d_ps_ep");
}

static grub_err_t
grub_cmd_d_ps (grub_command_t cmd __attribute__ ((unused)),
                         int argc, char **args)
{
  struct d_pi info;

  if (argc < 1 || !args[0] || !args[0][0])
    {
      clr_ps_env ();
      return 0;
    }

  grub_memset (&info, 0, sizeof (info));
  clr_ps_env ();
  read_partset_file (args[0], &info);

  set_or_unset_env ("d_ps_src", args[0]);
  if (info.valid)
    grub_env_set ("d_ps_ok", "1");
  set_or_unset_env ("d_ps_rf", info.rootfs);
  set_or_unset_env ("d_ps_ef", info.efi);
  set_or_unset_env ("d_ps_vr", info.var);
  set_or_unset_env ("d_ps_hm", info.home);
  set_or_unset_env ("d_ps_ep", info.esp);

  grub_free (info.rootfs);
  grub_free (info.efi);
  grub_free (info.var);
  grub_free (info.home);
  grub_free (info.esp);
  return 0;
}

static grub_err_t
grub_cmd_d_rr (grub_command_t cmd __attribute__ ((unused)),
               int argc, char **args)
{
  struct d_ru_ctx ctx;
  char *want;
  const char *var = "root";

  if (argc >= 2 && args[1] && args[1][0])
    var = args[1];

  if (argc < 1 || !args[0] || !args[0][0])
    {
      grub_env_unset (var);
      return GRUB_ERR_NONE;
    }

  want = d_uuid_cp (args[0]);
  if (!want)
    {
      grub_env_unset (var);
      return GRUB_ERR_NONE;
    }

  ctx.want = want;
  ctx.found = 0;
  grub_device_iterate (d_find_partuuid_iter, &ctx);

  if (ctx.found)
    grub_env_set (var, ctx.found);
  else
    grub_env_unset (var);

  grub_free (ctx.found);
  grub_free (want);
  grub_errno = GRUB_ERR_NONE;
  return GRUB_ERR_NONE;
}

static grub_err_t
grub_cmd_d_cf (grub_command_t cmd __attribute__ ((unused)),
                      int argc, char **args)
{
  struct d_ci info_a;
  struct d_ci info_b;
  char *path_a;
  char *path_b;
  const char *reason = 0;
  char slot = 0;

  if (argc < 1)
    return grub_error (GRUB_ERR_BAD_ARGUMENT, "usage: d_cf <conf_dir>");

  clr_cf_env ();
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
      grub_env_set ("d_sl", slot_buf);
    }
  if (reason)
    grub_env_set ("d_rs", reason);

  if (info_a.valid)
    {
      set_u64_env ("d_a_rq", info_a.boot_requested_at);
      set_u64_env ("d_a_tm", info_a.boot_time);
      set_u64_env ("d_a_ct", info_a.boot_count);
      if (info_a.reboot_self)
        grub_env_set ("d_a_sf", "1");
      set_or_unset_env ("d_a_md", info_a.mode);
    }
  if (info_b.valid)
    {
      set_u64_env ("d_b_rq", info_b.boot_requested_at);
      set_u64_env ("d_b_tm", info_b.boot_time);
      set_u64_env ("d_b_ct", info_b.boot_count);
      if (info_b.reboot_self)
        grub_env_set ("d_b_sf", "1");
      set_or_unset_env ("d_b_md", info_b.mode);
    }

  grub_free (info_a.mode);
  grub_free (info_b.mode);

  return 0;
}

static grub_command_t cmd_conf;
static grub_command_t cmd_partset;
static grub_command_t cmd_resolve_partuuid;

GRUB_MOD_INIT(decksb_conf)
{
  cmd_conf = grub_register_command ("d_cf", grub_cmd_d_cf,
                                    N_("CONF_DIR"),
                                    N_("Parse SteamOS bootconf and set d_sl."));
  cmd_partset = grub_register_command ("d_ps", grub_cmd_d_ps,
                                       N_("PARTSET_FILE"),
                                       N_("Parse SteamOS partset file and set d_ps_* vars."));
  cmd_resolve_partuuid = grub_register_command ("d_rr", grub_cmd_d_rr,
                                                N_("PARTUUID [VARNAME]"),
                                                N_("Resolve PARTUUID to device and set VARNAME (default root)."));
}

GRUB_MOD_FINI(decksb_conf)
{
  grub_unregister_command (cmd_conf);
  grub_unregister_command (cmd_partset);
  grub_unregister_command (cmd_resolve_partuuid);
}
