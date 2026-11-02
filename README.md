# Predictive Methods Project: Dengue in Brazilian Municipalities

Group project for the **Predictive Methods** course (Aix-Marseille University).
We use weekly dengue surveillance data from [InfoDengue](https://info.dengue.mat.br)
for all Brazilian municipalities to build:

1. a **cross-section prediction** model;
2. a **time series forecast**.

### Possible extension: other arboviruses

InfoDengue also tracks **chikungunya** and **zika**, transmitted by the same
mosquito (*Aedes aegypti*). The download script already supports them, so the
analysis can be extended to compare the three diseases or to use them as
additional predictors. Note that chikungunya and zika only reached Brazil
around 2014-2015, so their series start later than dengue.

## Repository structure

```
Predictive-Methods-Project/
├── Predictive-Methods-Project.Rproj   # open this file to start working
├── README.md
├── .gitignore
├── R/                                 # scripts, run in numerical order
│   ├── 01_download_infodengue.R       # downloads raw data from the InfoDengue API
│   ├── 02_cleaning.R                  # (to do) builds the clean panel
│   ├── 03_cross_section.R             # (to do) cross-section models
│   └── 04_time_series.R               # (to do) time series forecasts
├── analysis/
│   └── eda.Rmd                        # exploratory data analysis, knit to HTML
├── report/
│   └── report.Rmd                     # (to do) final report
├── data/                              # NOT tracked by git, created by the scripts
│   ├── raw/
│   └── processed/
└── output/
    ├── figures/                       # plots used in the report (tracked)
    └── models/                        # fitted models (NOT tracked)
```

## Setup

### 1. Software

- **R** >= 4.5
- **RStudio** (Pandoc for knitting `.Rmd` files is already included)

### 2. Clone and open the project

In RStudio: **File → New Project → Version Control → Git**, paste the repository URL.

Always open the project by double-clicking `Predictive-Methods-Project.Rproj`.
This sets the working directory to the repository root, which all scripts rely on.

### 3. Install the packages

Run once in the R console:

```r
install.packages(c(
  "httr2",      # API requests (>= 1.1.0)
  "jsonlite",   # JSON parsing
  "tidyverse",  # dplyr, readr, purrr, ggplot2, ...
  "here",       # project-relative paths in .Rmd files
  "rmarkdown",  # knitting reports
  "knitr",
  "arrow"       # optional: also saves the data as .parquet
))
```

## How to run

### Step 1: download the data

Open `R/01_download_infodengue.R` and click **Source**.

- It downloads the weekly series (from 2010 to the current year) for all
  ~5,570 municipalities. **The full run takes a while**: leave it running
  and keep the computer awake.
- To test it quickly first, set `TEST_MODE <- TRUE` (only 20 municipalities).
- The script is **resumable**: if it stops, run it again and it only
  downloads the missing municipalities.
- Diseases are set in the `DISEASES` parameter (`"dengue"`, `"chikungunya"`, `"zika"`).

Output: `data/processed/infodengue_dengue.rds`, one row per municipality per
epidemiological week.

```r
dengue <- readRDS("data/processed/infodengue_dengue.rds")
```

### Step 2 onwards

Run the scripts in `R/` in numerical order. Each script reads the output of the
previous one, so there is no need to rerun the download.

### Knitting the `.Rmd` files

When knitting, R uses the folder of the `.Rmd` file as the working directory,
not the project root. **Always build paths with `here()`** in `.Rmd` files:

```r
library(here)
dengue <- readRDS(here("data", "processed", "infodengue_dengue.rds"))
```

## Working conventions

- Code, comments, file names and commit messages are in **English**.
- **Do not commit data**: `data/` is in `.gitignore`; everyone regenerates it
  with `01_download_infodengue.R`.
- Heavy computations go in the `R/` scripts, which save their results.
  The `.Rmd` files only read those results, so knitting stays fast.
- Untick **Source on Save** / **Knit on Save** in RStudio, otherwise saving a
  file reruns the whole download or report.
- `git pull` before starting to work, commit and push often.

## Data source

- **InfoDengue** public API (`alertcity` endpoint): weekly notified and
  estimated cases, incidence, alert level, population and climate variables
  per municipality. Main columns: `data_iniSE` (week start date), `SE`
  (epidemiological week, `YYYYWW`), `casos` (notified cases), `casos_est`
  (cases corrected for notification delay), `p_inc100k` (incidence per 100k),
  `pop`, `nivel` (alert level 1-4).
- **List of municipalities**: IBGE API, with
  [kelvins/municipios-brasileiros](https://github.com/kelvins/municipios-brasileiros)
  as a fallback when the IBGE server is unreachable.
