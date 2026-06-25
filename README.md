# charon: The DeMON lab's in-house PET preprocessing pipeline

<table><tr>
<td><img src="charon.png" alt="charon logo" width="400"/></td>
<td valign="middle">

Charon automates the full workflow from raw BIDS data to preprocessed PET images by pairing MRI and PET scans by subject and date, running **FastSurfer** (segmentation + surface reconstruction) and **PETprep**, and producing a compressed archive of all outputs with a per-subject processing status report.

All processing is dispatched as a chain of SLURM jobs. The main script (`charon.sh`) returns immediately after submission and does not block waiting for jobs to finish.

</td>
</tr></table>

---

## Table of contents

1. [Prerequisites](#prerequisites)
2. [Repository structure](#repository-structure)
3. [Dataset requirements](#dataset-requirements)
4. [Quick start](#quick-start)
5. [Arguments](#arguments)
6. [Run configuration file](#run-configuration-file)
7. [Image pairs](#image-pairs)
8. [Pipeline steps](#pipeline-steps)
9. [Output structure](#output-structure)
10. [Pilot mode](#pilot-mode)
11. [Reuse mode](#reuse-mode)
12. [Troubleshooting](#troubleshooting)

---

## Prerequisites

| Dependency | Notes |
|---|---|
| **bash ≥ 4.0** | Required on the HPC node where `charon.sh` is launched. |
| **SLURM** | All processing jobs are submitted via `sbatch`. |
| **Singularity / Apptainer** | Loaded via `module load singularity` inside each job script. |
| **FastSurfer SIF** | GPU-capable Singularity image for brain segmentation and surface reconstruction. |
| **PETprep SIF** | Singularity image for PET preprocessing. |
| **FreeSurfer license** | A valid `license.txt` file. |
| **TemplateFlow cache** | A pre-populated TemplateFlow directory accessible from compute nodes. |

---

## Repository structure

```
charon/
├── scripts/
│   ├── charon.sh               # Entry point, the only script that is directly called by the user
│   ├── setup.sh                # Validates arguments, writes config, runs get_image_pairs.sh
│   ├── setup_subject.sh        # Creates per-subject directory structure
│   ├── get_image_pairs.sh      # Finds or validates MRI/PET pairs
│   ├── run_fastsurfer.sh       # Submits FastSurfer seg + surf SLURM jobs
│   ├── run_petprep.sh          # Submits PETprep SLURM job
│   ├── run_statistics.sh       # Stub (not yet implemented)
│   ├── run_qc.sh               # Stub (not yet implemented)
│   ├── finalize.sh             # Writes status TSV and compresses fastsurfer/charon outputs
│   ├── config/
│   │   ├── defaults.sh                  # Default values for all arguments
│   │   └── run_config_template.yaml     # Template for SLURM + tool options
│   └── utils/
│       └── logging.sh                   # Shared logging functions
└── README.md
```

---

## Dataset requirements

Charon expects a **BIDS-compliant** dataset. The exact structure depends on the session format used:

**Default (`--ses_format date`)** — session labels encode the scan date:
```
<dataset_dir>/<dataset>/raw/
  sub-<label>/
    ses-<YYYYMMDD>/
      anat/  sub-<label>_ses-<YYYYMMDD>_*_T1w.nii.gz
      pet/   sub-<label>_ses-<YYYYMMDD>*trc-<tracer>*pet.nii.gz
```

**Label sessions (`--ses_format label`)** — session labels are arbitrary identifiers:
```
<dataset_dir>/<dataset>/raw/
  sub-<label>/
    ses-<label>/          # e.g. ses-bl, ses-fu1, ses-v2
      anat/  sub-<label>_ses-<label>_*_T1w.nii.gz
      pet/   sub-<label>_ses-<label>*trc-<tracer>*pet.nii.gz
```

**No sessions (`--no_session`)** — no session level at all:
```
<dataset_dir>/<dataset>/raw/
  sub-<label>/
    anat/  sub-<label>_*_T1w.nii.gz
    pet/   sub-<label>*trc-<tracer>*pet.nii.gz
```

One requirement applies to all modes:

- T1w files must live under an `anat/` directory; PET files must live under a `pet/` directory.

When using `--ses_format date` (the default), an additional requirement applies:

- **Session labels must encode the scan date as `YYYYMMDD`** (e.g. `ses-20230415`). Files without an 8-digit date in their session label will cause an error.

---

## Quick start

### 1. Clone the repository

```bash
git clone https://github.com/hannahbaumeister/charon/
cd charon
```

### 2. Create your run configuration file

```bash
cp scripts/config/run_config_template.yaml my_run_config.yaml
# Fill in your SLURM details and tool options
```

### 3. Run the pipeline

```bash
bash scripts/charon.sh \
    --dataset           cohort_name \
    --dataset_dir       /path/to/bids \
    --tracer            tracer_label \
    --workdir           /path/to/workdir \
    --fs_license        /path/to/license.txt \
    --petprep_sif       /path/to/petprep.sif \
    --fastsurfer_sif    /path/to/fastsurfer.sif \
    --templateflow_home /path/to/templateflow \
    --run_config        my_run_config.yaml
```

`charon.sh` will validate inputs, find MRI/PET pairs, submit all SLURM jobs, and return. Monitor job progress with `squeue`. Since `--outdir` is omitted above, it defaults to `/path/to/bids/cohort_name/derivatives`; pass `--outdir` explicitly to put it elsewhere.

---

## Arguments

### Required

| Argument | Description |
|---|---|
| `--dataset` | Dataset name (e.g. `ADNI`). Used to locate `<dataset_dir>/<dataset>/`. |
| `--dataset_dir` | Path to the directory containing the dataset. |
| `--tracer` | Tracer name as it appears in the filename (e.g. `ftp`, `mk6240`). |
| `--workdir` | Working directory. Created if absent. All intermediate outputs go here. |
| `--fs_license` | Path to a valid FreeSurfer `license.txt`. |
| `--petprep_sif` | Path to the PETprep Singularity image. |
| `--fastsurfer_sif` | Path to the FastSurfer Singularity image. |
| `--templateflow_home` | Path to a local TemplateFlow cache accessible from compute nodes. |
| `--run_config` | Path to the run configuration file (SLURM resources + tool options). See [Run configuration file](#run-configuration-file). |

### Optional

| Argument | Default | Description |
|---|---|---|
| `--outdir` | `<dataset_dir>/<dataset>/derivatives` | Output directory. Final archives and status TSV are written here. |
| `--mri_pet_daydiff` | `10000` | Maximum number of days allowed between the T1w and PET scan dates. The default is set absurdly high so all available pairs are kept unless you lower it. Ignored if `--image_pairs` is provided. |
| `--scan_selection` | `earliest` | When multiple valid pairs exist for a subject, keep the `earliest` or `latest` PET scan date, or `all` to retain every valid pair. Ignored if `--image_pairs`, `--no_session`, or `--ses_format label` is provided. |
| `--ses_format` | `date` | Session label format. `date`: labels must be `YYYYMMDD` and scans are paired by date. `label`: labels are arbitrary (e.g. `bl`, `fu1`) and scans are paired by subject + matching session label. `--mri_pet_daydiff` and `--scan_selection` are ignored. |
| `--no_session` | `false` | Dataset has no session level, charon pairs T1w and PET scans by subject only. `--mri_pet_daydiff` and `--scan_selection` are ignored. |
| `--image_pairs` | — | Path to a pre-existing image pairs TSV (see [Image pairs](#image-pairs)). If provided, auto-discovery is skipped and the file is validated instead. |
| `--reuse` | `false` | Skip steps whose outputs already exist in `--workdir`. Useful when resuming a partially completed run. |
| `--pilot` | `false` | Skip container file validation and Singularity version checks. Intended for local testing without SIF files. |

---

## Run configuration file

The run configuration file controls SLURM resources and tool-level flags for each processing step. Copy the template and fill in your values:

```bash
cp scripts/config/run_config_template.yaml my_run_config.yaml
```

Pass it to the pipeline with `--run_config my_run_config.yaml`. See `scripts/config/run_config_template.yaml` itself for the full list of options — every option there has an inline comment explaining what it does, so it's kept as the single source of truth rather than duplicated here.

**Empty values** are omitted from the generated SLURM job script and SLURM will use its cluster defaults. **Boolean flags** must be explicitly set to `true` to be included; any other value (including blank) means the flag is omitted.

---

## Image pairs

Charon needs to know which T1w scan to pair with which PET scan for each subject. There are two modes:

### Auto-discovery (default)

When `--image_pairs` is not provided, charon searches the dataset for all T1w and PET files, matches them by subject ID, and keeps only pairs where the scan dates are within `--mri_pet_daydiff` days of each other. If a subject has multiple valid pairs, `--scan_selection` (`earliest`, `latest`, or `all`) picks one or keeps all.

The discovered pairs are saved to `<workdir>/charon_crosssectional_<tracer>/image_pairs.tsv` and written to the pipeline config.

**Subjects that have both modalities but no pair within the day range produce a warning (not an error) and are skipped**.

### Provided TSV

Pass `--image_pairs /path/to/pairs.tsv` to supply your own pairing. The file must be tab-separated with a header row:

```
subject	pet_path	t1_path	day_diff
sub-001	/path/to/pet.nii.gz	/path/to/t1.nii.gz	20
```

Charon validates that all files exist and logs a warning for any that are missing — rows are kept regardless. Subjects with missing input files will appear as `file_not_found` across all status columns in the processing status TSV. `--mri_pet_daydiff` and `--scan_selection` are ignored when a pairs file is provided.

---

## Pipeline steps

For each subject in the pairs file, charon submits the following SLURM job chain:

```
setup_subject  (local, synchronous)
     │
     ▼
 seg_<id>         ← FastSurfer segmentation  (GPU)
     │ afterok
     ▼
 surf_<id>        ← FastSurfer surface recon (CPU)
     │ afterok
     ▼
 pp_<id>          ← PETprep                  (CPU)
     │
     └──────────────────────┐
                            ▼ afterany (all subjects)
                    finalize    ← Status TSV + archive
```

- **`fs_seg`** runs FastSurfer with `--seg_only` using a GPU node. Skipped entirely if `recon-all.done` already exists for this (subject, T1 session) — see [Reuse mode](#reuse-mode).
- **`fs_surf`** runs FastSurfer with `--surf_only` on a CPU node, depending on `fs_seg` completing successfully. Also skipped if already complete.
- **`petprep`** runs PETprep on the full BIDS dataset for one participant, depending on `fs_surf` completing successfully (no dependency if FastSurfer was reused). Skipped entirely if a previous run for this subject/session already logged `PETPrep finished successfully!` — checked regardless of `--reuse`, the same way FastSurfer's reuse check works. Unlike FastSurfer, PETprep has no sentinel *file*, so this is detected from its own SLURM log (`pp_<participant>_*.log`) rather than an output artifact.
- **`finalize`** runs after **all** *actually-submitted* PETprep jobs have finished (regardless of success/failure), writes the status TSV, and compresses `fastsurfer_crosssectional/` and `charon_crosssectional_<tracer>/` into separate archives. If every subject in the run was reused (no fresh PETprep jobs at all), `finalize` is still submitted, just without a `--dependency` — there's nothing left to wait on.

`charon.sh` itself returns immediately after all jobs are submitted.

---

## Output structure

`--workdir` contains two kinds of folders: one shared, tracer-independent `fastsurfer_crosssectional/`, and one `charon_crosssectional_<tracer>/` per `--tracer` you've run against this workdir. This lets multiple tracers share the same anatomical (T1w) FastSurfer output instead of recomputing it per tracer — FastSurfer is keyed by the T1w scan's **own** session label, not the PET session it happens to be paired with, so the same recon is reused for every PET pair (any tracer, any --scan_selection all duplicate) that shares that T1w scan.

### During processing: `<workdir>/`

```
workdir/
├── fastsurfer_crosssectional/                  # Shared across all tracer runs in this workdir
│   └── sub-<label>/
│       └── ses-<t1_label>/        # session label from the T1w filename; omitted for --no_session datasets
│           ├── logs/
│           │   ├── seg_<id>_<jobid>.log
│           │   └── surf_<id>_<jobid>.log
│           └── sub-<label>/
│               ├── mri/        # Segmentation outputs (aparc.DKTatlas+aseg.deep.mgz, etc.)
│               ├── surf/       # Surface files (lh.pial, rh.pial, etc.)
│               ├── label/
│               └── stats/
│
└── charon_crosssectional_<tracer>/             # One per --tracer run against this workdir
    ├── charon_config.yaml                          # Resolved pipeline configuration
    ├── charon.log                                  # Full pipeline log (including finalize output)
    ├── image_pairs.tsv                             # MRI/PET pairs used for this run
    ├── run_config.yaml                             # Copy of your run configuration file
    ├── charon_crosssectional_<tracer>_processing_status.tsv   # Per-subject status (written by finalize)
    │
    ├── bids/                                       # Fake BIDS dir built by build_fake_bids.sh (symlinks to real T1w/PET files)
    │   ├── dataset_description.json
    │   └── sub-<label>/
    │       └── ses-<pet_label>/
    │           ├── anat/   sub-<label>_ses-<pet_label>_*_T1w.nii.gz   # symlink
    │           └── pet/    sub-<label>_ses-<pet_label>_*_pet.nii.gz   # symlink
    │
    └── sub-<label>/
        └── ses-<pet_label>/           # session label from the PET filename; omitted for --no_session datasets
            ├── logs/
            │   └── pp_<id>_<jobid>.log
            ├── fastsurfer -> ../../../../fastsurfer_crosssectional/sub-<label>/ses-<t1_label>   # symlink
            └── petprep/
                └── sub-<label>/    # PETprep outputs
                    └── ses-<label>/
                        ├── pet/
                        └── figures/
```

### After finalize: per-session compaction

After writing the status TSV, and *before* building the two full archives below, `finalize.sh` compresses each `sub-<label>/ses-<label>/` directory **in place**, on both sides, and deletes the live directory. It also compresses the fake `bids/` directory the same way:

```
fastsurfer_crosssectional/sub-<label>/ses-<t1_label>.tar.gz
charon_crosssectional_<tracer>/sub-<label>/ses-<pet_label>.tar.gz
charon_crosssectional_<tracer>/bids.tar.gz
```

(For `--no_session` datasets, the leaf directory is `sub-<label>/` itself, so it's `sub-<label>.tar.gz`.)

This saves disk space in `--workdir`, and because it runs *before* the full archives are built, the full archives end up containing these compressed `.tar.gz` files rather than raw directories — extracting `fastsurfer_crosssectional.tar.gz` from `outdir` gives you `sub-<label>/ses-<t1_label>.tar.gz`, not a live `mri/`/`surf/` tree, and extracting `charon_crosssectional_<tracer>.tar.gz` gives you `bids.tar.gz` rather than a live `bids/` directory of symlinks. If a later `charon.sh` run (e.g. a different `--tracer`) needs to reuse an already-archived FastSurfer session, `run_fastsurfer.sh` transparently re-extracts it before checking for `recon-all.done`. There is no equivalent transparent re-extraction for `bids.tar.gz` — if you `--reuse` a tracer run after its `finalize.sh` has already run, `setup.sh` will simply rebuild `bids/` from scratch (cheap, since it's just symlinks).

### Final outputs: `<outdir>/`

```
outdir/
├── fastsurfer_crosssectional.tar.gz                         # Compressed fastsurfer_crosssectional/ (sessions already compacted to per-session .tar.gz, see above)
└── charon_crosssectional_<tracer>.tar.gz                    # Compressed charon_crosssectional_<tracer>/ (sessions already compacted; petprep/work excluded)
```

The processing status TSV itself lives at `<workdir>/charon_crosssectional_<tracer>/charon_crosssectional_<tracer>_processing_status.tsv` and is included inside the second archive — it is not written to `outdir` separately.

The two archives are independent — the `fastsurfer` symlink inside `charon_crosssectional_<tracer>.tar.gz` is **not** dereferenced, so it will dangle if you extract that archive standalone without also extracting `fastsurfer_crosssectional.tar.gz` alongside it.

### After finalize: workdir cleanup

Once both full archives above are written, `finalize.sh` makes a second pass over the status TSV and deletes the now-redundant per-session `.tar.gz` from `--workdir` for every row that succeeded — independently on each side:

- **Charon side**: `sub-<label>/ses-<pet_label>.tar.gz` is removed if that row's `petprep` status is `success`.
- **FastSurfer side**: `sub-<label>/ses-<t1_label>.tar.gz` is removed if both `fastsurfer_seg` and `fastsurfer_surf` are `success` — this is a **shared** recon, so it's deleted from `--workdir` even though other tracer runs against the same `--workdir` (or even a concurrently running one) might otherwise have reused it directly; see [Restoring from `--outdir`](#restoring-from---outdir) for how a later run recovers it from the archive instead.

Failed (or `file_not_found`) rows are left untouched in `--workdir` for inspection or a later `--reuse` retry.

If **every** row in the status TSV succeeded, the entire `charon_crosssectional_<tracer>/` working directory is removed — but `charon.log` and `charon_config.yaml` are copied to `outdir/charon_crosssectional_<tracer>.log` and `outdir/charon_crosssectional_<tracer>_config.yaml` first, since `finalize.sh`'s own SLURM job is still appending to `charon.log` inside the directory it's about to delete, and that record would otherwise be lost. If even one row failed, the directory (now containing only the failed rows' data, plus the config/log/pairs/bids files) is kept as-is.

The status TSV contains one row per image pair with columns:

```
subject  t1_path  pet_path  day_diff  fastsurfer_seg  fastsurfer_surf  petprep
```

Success is determined by:
- **fastsurfer_seg**: presence of `mri/aparc.DKTatlas+aseg.deep.mgz`
- **fastsurfer_surf**: presence of `surf/lh.pial`
- **petprep**: `pp_<participant>_*.log` contains `PETPrep finished successfully!` — the same check `run_petprep.sh` uses to decide whether to skip resubmission

---

## Pilot mode

Pilot mode is designed for local testing on macOS without Singularity images, a FreeSurfer license, or a SLURM cluster. The full pipeline runs — setup, image pairing, and per-subject directory creation — but instead of submitting jobs, the batch scripts that **would** be submitted are printed to the terminal.

```bash
bash scripts/charon.sh \
    --dataset_dir pilot/dataset \
    --dataset     POINTER \
    --tracer      mk6240 \
    --workdir     pilot/workdir \
    --outdir      pilot/out \
    --pilot
```

In pilot mode:
- `--fs_license`, `--petprep_sif`, `--fastsurfer_sif`, `--templateflow_home`, and `--run_config` are **not required**.
- Container version checks are skipped.
- Per-subject working directories are created normally.
- No `sbatch` commands are issued; the full batch script for each job is echoed to the terminal instead.
- The finalize job is not submitted.

---

## Reuse mode

Pass `--reuse` to resume a run that was interrupted or partially completed:

```bash
bash scripts/charon.sh ... --workdir /existing/workdir --reuse
```

In reuse mode:
- The existing `charon_config.yaml` is kept as-is.
- The existing `image_pairs.tsv` is reused.
- Copied config files (`run_config.yaml`) are not overwritten.

Note: `--reuse` only controls what `setup.sh` preserves (config, image pairs, run config). FastSurfer and PETprep have their own independent reuse checks — see [Pipeline steps](#pipeline-steps) — that skip resubmission whenever a subject's previous run already completed successfully, regardless of whether `--reuse` was passed.

### Restoring from `--outdir`

`--workdir` is missing if a previous run on a cohort + tracer combination exited entirely successfully, since `finalize.sh` deletes a subject/session's data from `--workdir` as soon as it succeeds (see [After finalize: workdir cleanup](#after-finalize-workdir-cleanup)). As long as `--outdir` still holds the full archives, `setup.sh` and `run_fastsurfer.sh` transparently restore from there instead of starting over or reprocessing:

- **FastSurfer** (`fastsurfer_crosssectional/`): whenever `outdir/fastsurfer_crosssectional.tar.gz` exists, `setup.sh` restores it into `--workdir` before anything else runs — **regardless of `--reuse`** (consistent with FastSurfer's "always reuse a complete recon" behavior) and **regardless of whether `--workdir` already has some sessions locally**. 
- **Charon/tracer run** (`charon_crosssectional_<tracer>/`): if `charon_config.yaml` is missing locally **and `--reuse` is passed**, `setup.sh` extracts the whole `outdir/charon_crosssectional_<tracer>.tar.gz` into `--workdir` first, restoring `image_pairs.tsv`, `run_config.yaml`, `bids.tar.gz`, and the completed per-session archives. The existing-run check then proceeds exactly as if `--workdir` had never been touched. This is gated on `--reuse` (unlike the FastSurfer case, and because — unlike FastSurfer — a tracer's working directory is all-or-nothing rather than incrementally shared) so a plain re-run without `--reuse` against an empty `--workdir` still starts fresh rather than silently resurrecting a previous run.

Because this extraction can be large, `setup.sh` never runs it inline on the login node: it writes a small job script, submits it with `sbatch --wait`, and blocks until it completes (requires `restore_account` etc. in `--run_config`; see [Run configuration file](#run-configuration-file)). The one exception is `--pilot` mode, which has no SLURM access at all, so the extraction runs inline there. In these cases, `charon.sh` no longer always "returns immediately", as it needs to wait for this extraction job to finish before submitting all slurm jobs.

---

## Troubleshooting

**`No YYYYMMDD date found in session label`**
Only occurs with the default `--ses_format date`. The session label does not contain an 8-digit date. Options: rename sessions to `ses-YYYYMMDD`; use `--ses_format label` if sessions have non-date labels (e.g. `bl`, `fu1`); use `--no_session` if the dataset has no session level; or bypass discovery entirely with `--image_pairs`.

**`SLURM options file not found in config`**
`--run_config` is a required argument. Ensure it is passed and the file exists at the given path.

**FastSurfer seg/surf jobs immediately fail**
Check `<workdir>/fastsurfer_crosssectional/sub-<label>/ses-<t1_label>/logs/seg_*` and `surf_*`. Common causes: Singularity image not accessible from the compute node, GPU not allocated, or incorrect SIF path.

**PETprep job immediately fails**
Check `<workdir>/charon_crosssectional_<tracer>/sub-<label>/ses-<pet_label>/logs/pp_*`. Common causes: TemplateFlow directory not accessible from compute nodes, FastSurfer surf did not complete (check surf log), or insufficient memory.

**Finalize job never runs**
Ensure `finalize_account` is set in your run config. Also check that at least one subject made it through the per-subject loop without a submission failure — finalize is only submitted when `$N_SUCCESS -gt 0` (a subject counts here whether its PETprep job was freshly submitted or reused from a prior successful run).

**`A charon run already exists in: <workdir>/charon_crosssectional_<tracer>`**
A previous run with this `--tracer` (and `--workdir`) wrote a `charon_config.yaml` there. Either pass `--reuse` to continue that run, or use a different `--workdir` or `--tracer`. A different `--tracer` against the same `--workdir` is always treated as a new run and will reuse the shared `fastsurfer_crosssectional/` output where possible.

**Jobs depend on a cancelled job and stay blocked**
SLURM `afterok` dependencies are skipped if the parent job is cancelled. Use `scontrol` to release or cancel the dependent jobs manually.
