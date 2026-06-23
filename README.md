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
│   ├── finalize.sh             # Writes status TSV and compresses workdir
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
# Fill in your SLURM account, resources, and tool options
```

### 3. Run the pipeline

```bash
bash scripts/charon.sh \
    --dataset           cohort_name \
    --dataset_dir       /path/to/bids \
    --tracer            tracer_label \
    --suffix            myproject \
    --workdir           /path/to/workdir \
    --outdir            /path/to/outdir \
    --fs_license        /path/to/license.txt \
    --petprep_sif       /path/to/petprep.sif \
    --fastsurfer_sif    /path/to/fastsurfer.sif \
    --templateflow_home /path/to/templateflow \
    --run_config        my_run_config.yaml
```

`charon.sh` will validate inputs, find MRI/PET pairs, submit all SLURM jobs, and return. Monitor job progress with `squeue`.

---

## Arguments

### Required

| Argument | Description |
|---|---|
| `--dataset` | Dataset name (e.g. `ADNI`). Used to locate `<dataset_dir>/<dataset>/`. |
| `--dataset_dir` | Path to the directory containing the dataset. |
| `--tracer` | Tracer name as it appears in the filename (e.g. `ftp`, `mk6240`). |
| `--suffix` | Label for this processing run (e.g. `v1`, `myproject`). Used in output filenames. |
| `--workdir` | Working directory. Created if absent. All intermediate outputs go here. |
| `--outdir` | Output directory. Final archive and status TSV are written here. |
| `--fs_license` | Path to a valid FreeSurfer `license.txt`. |
| `--petprep_sif` | Path to the PETprep Singularity image. |
| `--fastsurfer_sif` | Path to the FastSurfer Singularity image. |
| `--templateflow_home` | Path to a local TemplateFlow cache accessible from compute nodes. |
| `--run_config` | Path to the run configuration file (SLURM resources + tool options). See [Run configuration file](#run-configuration-file). |

### Optional

| Argument | Default | Description |
|---|---|---|
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

Pass it to the pipeline with `--run_config my_run_config.yaml`.

### Full reference

```yaml
# ─── SLURM: FastSurfer segmentation (GPU) ────────────────────────────────────
fastsurfer_seg_account:       ""   # SLURM project account
fastsurfer_seg_cpus_per_task: ""   # Number of CPUs
fastsurfer_seg_mem:           ""   # Memory, e.g. 7G
fastsurfer_seg_gres:          ""   # GPU resource, e.g. gpu:1
fastsurfer_seg_constraint:    ""   # Node constraint, e.g. gpu
fastsurfer_seg_time:          ""   # Wall time HH:MM:SS

# ─── SLURM: FastSurfer surface reconstruction (CPU) ──────────────────────────
fastsurfer_surf_account:       ""
fastsurfer_surf_cpus_per_task: ""
fastsurfer_surf_mem:           ""
fastsurfer_surf_time:          ""

# ─── SLURM: PETprep ──────────────────────────────────────────────────────────
petprep_account:    ""
petprep_partition:  ""   # e.g. node
petprep_ntasks:     ""   # Number of tasks (used as --nthreads)
petprep_time:       ""

# ─── SLURM: Finalize ─────────────────────────────────────────────────────────
finalize_account:       ""
finalize_cpus_per_task: ""
finalize_mem:           ""
finalize_time:          ""

# ─── FastSurfer options ───────────────────────────────────────────────────────
fastsurfer_threads: ""      # Thread count; defaults to fastsurfer_seg_cpus_per_task

# ─── PETprep options ─────────────────────────────────────────────────────────
petprep_mem_mb:              32000
petprep_omp_nthreads:        ""     # Defaults to petprep_ntasks / 2
petprep_stop_on_first_crash: true
petprep_notrack:             true
petprep_verbose:             true
```

**Empty values** are omitted from the generated SLURM job script and SLURM will use its cluster defaults. **Boolean flags** must be explicitly set to `true` to be included; any other value (including blank) means the flag is omitted.

---

## Image pairs

Charon needs to know which T1w scan to pair with which PET scan for each subject. There are two modes:

### Auto-discovery (default)

When `--image_pairs` is not provided, charon searches the dataset for all T1w and PET files, matches them by subject ID, and keeps only pairs where the scan dates are within `--mri_pet_daydiff` days of each other. If a subject has multiple valid pairs, `--scan_selection` (`earliest`, `latest`, or `all`) picks one or keeps all.

The discovered pairs are saved to `<workdir>/image_pairs.tsv` and written to the pipeline config.

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

- **`fs_seg`** runs FastSurfer with `--seg_only` using a GPU node.
- **`fs_surf`** runs FastSurfer with `--surf_only` on a CPU node, depending on `fs_seg` completing successfully.
- **`petprep`** runs PETprep on the full BIDS dataset for one participant, depending on `fs_surf` completing successfully.
- **`finalize`** runs after **all** PETprep jobs have finished (regardless of success/failure), writes the status TSV, and compresses the workdir.

`charon.sh` itself returns immediately after all jobs are submitted.

---

## Output structure

### During processing: `<workdir>/`

```
workdir/
├── charon_config.yaml                          # Resolved pipeline configuration
├── charon.log                                  # Full pipeline log (including finalize output)
├── image_pairs.tsv                             # MRI/PET pairs used for this run
├── run_config.yaml                             # Copy of your run configuration file
├── <dataset>_<tracer>_<suffix>_processing_status.tsv   # Per-subject status (written by finalize)
│
├── sub-<label>/
│   └── ses-<pet_label>/           # session label from the PET filename; omitted for --no_session datasets
│       ├── logs/
│       │   ├── seg_<id>_<jobid>.log
│       │   ├── surf_<id>_<jobid>.log
│       │   └── pp_<id>_<jobid>.log
│       ├── fastsurfer/
│       │   └── sub-<label>/
│       │       ├── mri/        # Segmentation outputs (aparc.DKTatlas+aseg.deep.mgz, etc.)
│       │       ├── surf/       # Surface files (lh.pial, rh.pial, etc.)
│       │       ├── label/
│       │       └── stats/
│       └── petprep/
│           └── sub-<label>/    # PETprep outputs
│               └── ses-<label>/
│                   ├── pet/
│                   └── figures/
└── ...
```

### Final outputs: `<outdir>/`

```
outdir/
├── <dataset>_<tracer>_<suffix>.tar.gz                       # Compressed workdir (petprep/work excluded)
└── <dataset>_<tracer>_<suffix>_processing_status.tsv        # Also inside the archive
```

The status TSV contains one row per image pair with columns:

```
subject  t1_path  pet_path  day_diff  fastsurfer_seg  fastsurfer_surf  petprep
```

Success is determined by the presence of key output files:
- **fastsurfer_seg**: `mri/aparc.DKTatlas+aseg.deep.mgz`
- **fastsurfer_surf**: `surf/lh.pial`
- **petprep**: non-empty `sub-<participant>/` output directory

---

## Pilot mode

Pilot mode is designed for local testing on macOS without Singularity images, a FreeSurfer license, or a SLURM cluster. The full pipeline runs — setup, image pairing, and per-subject directory creation — but instead of submitting jobs, the batch scripts that **would** be submitted are printed to the terminal.

```bash
bash scripts/charon.sh \
    --dataset_dir pilot/dataset \
    --dataset     POINTER \
    --tracer      mk6240 \
    --suffix      pilot01 \
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

Note: `--reuse` only controls what `setup.sh` preserves. It does not prevent SLURM jobs from re-running — use SLURM dependencies or check outputs manually if you want to avoid reprocessing completed subjects.

---

## Troubleshooting

**`No YYYYMMDD date found in session label`**
Only occurs with the default `--ses_format date`. The session label does not contain an 8-digit date. Options: rename sessions to `ses-YYYYMMDD`; use `--ses_format label` if sessions have non-date labels (e.g. `bl`, `fu1`); use `--no_session` if the dataset has no session level; or bypass discovery entirely with `--image_pairs`.

**`SLURM options file not found in config`**
`--run_config` is a required argument. Ensure it is passed and the file exists at the given path.

**FastSurfer seg/surf jobs immediately fail**
Check `<workdir>/sub-<label>/logs/fs_seg_*`. Common causes: Singularity image not accessible from the compute node, GPU not allocated, or incorrect SIF path.

**PETprep job immediately fails**
Check `<workdir>/sub-<label>/logs/petprep_*`. Common causes: TemplateFlow directory not accessible from compute nodes, FastSurfer surf did not complete (check surf log), or insufficient memory.

**Finalize job never runs**
Ensure `finalize_account` is set in your run config. Also check that at least one PETprep job was submitted successfully — finalize is only submitted when `ALL_PETPREP_JOB_IDS` is non-empty.

**`A charon run already exists in: <workdir>`**
A previous run wrote a `charon_config.yaml` to that workdir. Either pass `--reuse` to continue the run, or specify a different `--workdir`.

**Jobs depend on a cancelled job and stay blocked**
SLURM `afterok` dependencies are skipped if the parent job is cancelled. Use `scontrol` to release or cancel the dependent jobs manually.
