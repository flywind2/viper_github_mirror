# vim: syntax=python tabstop=4 expandtab
# coding: utf-8

import os
import sys
import subprocess
from collections import defaultdict
import pandas as pd
import yaml
from scripts.viper_report import get_sphinx_report
from snakemake.utils import report

#-----     CONFIG SET UP    ------#
configfile: "config.yaml"

with open("ref.yaml","r") as ref_file:
    ref_info = yaml.safe_load(ref_file) 

for k,v in ref_info.items():
    config[k] = v

config["samples"] = config["the_samples"]
config["config_file"] = "config.yaml" # trick to force rules on config change
for k in ["RPKM_threshold","min_num_samples_expressing_at_threshold","SSnumgenes","SFnumgenes","num_kmeans_clust","filter_mirna","snp_scan_genome"]:
    config[k] = str(config[k])

conda_root = subprocess.check_output('conda info --root',shell=True).decode('utf-8').strip()
#NEED to append 'pkgs' to the conda_root path to get to the bins
conda_path = os.path.join(conda_root, 'pkgs')
#NEED the following when invoking python2 (to set proper PYTHONPATH)
#MOVING from conda env named "python2" to "viper_py2"
python2_pythonpath = os.path.join(conda_root, 'envs', 'viper_py2', 'lib', 'python2.7', 'site-packages')

if not "python2" in config or not config["python2"]:
    config["python2"] = conda_path + '/python-2.7.9-3/bin/python2.7'

if not "rseqc_path" in config or not config["rseqc_path"]:
    config["rseqc_path"] = conda_path + '/rseqc-2.6.2-0/bin'

if not "picard_path" in config or not config["picard_path"]:
    #config["picard_path"] = conda_path + '/picard-1.141-1/bin/picard'
    config["picard_path"] = 'picard' #subprocess.check_output('which picard',shell=True).decode('utf-8').strip()

if not "varscan_path" in config or not config["varscan_path"]:
    #config["varscan_path"] = conda_path + '/varscan-2.4.1-0/bin/varscan'
    config["varscan_path"] = 'varscan' #subprocess.check_output('which varscan',shell=True).decode('utf-8').strip()
#----   END OF CONFIG SET UP -----#

strand_command=""
cuff_command=""
rRNA_strand_command=""

if( config["stranded"] ):
    strand_command="--outFilterIntronMotifs RemoveNoncanonical"
    cuff_command="--library-type " + config["library_type"]
    rRNA_strand_command="--outFilterIntronMotifs RemoveNoncanonical"
else:
    strand_command="--outSAMstrandField intronMotif"
    rRNA_strand_command="--outSAMstrandField intronMotif"

#------------------------------------------------------------------------------
#metasheet pre-parser: converts dos2unix, catches invalid chars
_invalid_map = {'\r':'\n', '-':'.', '(':'.', ')':'.', ' ':'_', '/':'.', '$':''}
_meta_f = open(config['metasheet'])
_meta = _meta_f.read()
_meta_f.close()

_tmp = _meta.replace('\r\n','\n')
#check other invalids
for k in _invalid_map.keys():
    if k in _tmp:
        _tmp = _tmp.replace(k, _invalid_map[k])

#did the contents change?--rewrite the metafile
if _meta != _tmp:
    #print('converting')
    _meta_f = open(config['metasheet'], 'w')
    _meta_f.write(_tmp)
    _meta_f.close()
#------------------------------------------------------------------------------

metadata = pd.read_table(config['metasheet'], index_col=0, sep=',')
comparisons = comparison=[c[5:] for c in metadata.columns if c.startswith("comp_")]

metacols = [c for c in metadata.columns if c.lower()[:4] != 'comp']

# Mahesh changing the metasheet match with config info to using pandas #
file_info = { sampleName : config["samples"][sampleName] for sampleName in metadata.index }
ordered_sample_list = metadata.index
run_fusion= True if len(config["samples"][metadata.index[0]]) == 2 else False
gz_command="--readFilesCommand zcat" if config["samples"][metadata.index[0]][0][-3:] == '.gz' else ""

#make sure the input is not a mixture of SE and PE
for cur_index in range(1,len(metadata.index)):
    if len(config["samples"][metadata.index[cur_index]]) != len(config["samples"][metadata.index[0]]):
        sys.stderr.write("Input is a mixture of SE and PE. This feature is not currently supported by VIPER. Exiting .... \n")
        sys.exit(1)

if( run_fusion ):
    if( config["stranded"] ):
        strand_command = " --outFilterIntronMotifs RemoveNoncanonicalUnannotated --outReadsUnmapped None --chimSegmentMin 12 --chimJunctionOverhangMin 12 --alignSJDBoverhangMin 10 --alignMatesGapMax 200000 --alignIntronMax 200000"
    else:
        strand_command = " --outFilterIntronMotifs RemoveNoncanonicalUnannotated --outReadsUnmapped None --chimSegmentMin 12 --chimJunctionOverhangMin 12 --alignSJDBoverhangMin 10 --alignMatesGapMax 200000 --alignIntronMax 200000 --outSAMstrandField intronMotif"

#GENERATE snp regions list:
#DEPRECATED-snp_regions- with genome wide scans we are only outputting vcf file
#snp_regions = ['hla', 'genome'] if ('snp_scan_genome' in config) and config['snp_scan_genome'] == 'true' else ['hla']

#NOTE: chr6 scans should be limited to JUST the HLA region, not the whole chr
#NOTE: in mice, HLA region is actually on chr17!
#HENCE the renaming of snp.chr6.txt to snp.hla.txt
_HLA_regions = {'hg19':"chr6:28477797-33448354", 'mm9':'chr17:34111604-36221194'}


## Returns proper count files for with and without batch effect correction
def get_STAR_counts(config, normalized=False):
    if config["batch_effect_removal"] == "true":
        return "analysis/STAR/batch_corrected_STAR_Gene_Counts.csv"
    else:
        return "analysis/STAR/STAR_Gene_Counts.csv"

def get_cuff_counts(config, normalized=False):
    if config["batch_effect_removal"] == "true":
        return "analysis/cufflinks/batch_corrected_Cuff_Gene_Counts.csv"
    else:
        return "analysis/cufflinks/Cuff_Gene_Counts.csv"

## Other functions for snakefile
def get_fastq(wildcards):
    return file_info[wildcards.sample]

def fusion_output(wildcards):
    fusion_out = []
    if run_fusion:
        fusion_out.append("analysis/STAR_Fusion/STAR_Fusion_Report.png")
    return fusion_out

def insert_size_output(wildcards):
    insert_size_out_files = []
    if run_fusion:
        for sample in file_info.keys():
            insert_size_out_files.append( "analysis/RSeQC/insert_size/" + sample + "/" + sample + ".histogram.pdf" )
    return insert_size_out_files

def rRNA_metrics(wildcards):
    if config["star_rRNA_index"] is not None:
        return "analysis/STAR_rRNA/STAR_rRNA_Align_Report.csv"

def de_summary_out_png(wildcards):
    file_list = []
    if comparisons:
        file_list.append("analysis/diffexp/de_summary.png")
    return file_list

def run_snp_genome(wildcards):
    ls = []
    if ('snp_scan_genome' in config) and (config['snp_scan_genome'].upper() == 'TRUE'):
        for sample in ordered_sample_list:
            #ls.append("analysis/snp/%s/%s.snp.genome.vcf" % sample)
            #NOTE: LINE BELOW IS VERY ugly, but it's the only way it will work!
            ls.append("analysis/snp/"+sample+"/"+sample+".snp.genome.vcf")
    return ls

rule target:
    input:
        expand( "analysis/cufflinks/{K}/{K}.genes.fpkm_tracking", K=ordered_sample_list ),
        "analysis/STAR/STAR_Align_Report.csv",
        "analysis/STAR/STAR_Align_Report.png",
        get_STAR_counts(config),
        get_cuff_counts(config),
	    ["analysis/STAR/star_combat_qc.pdf", "analysis/cufflinks/cuff_combat_qc.pdf"] if config["batch_effect_removal"] == "true" else[],
        "analysis/plots/pca_plot.pdf",
        expand("analysis/plots/images/pca_plot_{metacol}.png", metacol=metacols),
        "analysis/plots/heatmapSS_plot.pdf",
        "analysis/plots/heatmapSF_plot.pdf",
        expand( "analysis/RSeQC/read_distrib/{sample}.txt", sample=ordered_sample_list ),
        "analysis/RSeQC/read_distrib/read_distrib.png",
        expand( "analysis/RSeQC/gene_body_cvg/{sample}/{sample}.geneBodyCoverage.curves.png", sample=ordered_sample_list ),
        "analysis/RSeQC/gene_body_cvg/geneBodyCoverage.heatMap.png",
        expand( "analysis/RSeQC/junction_saturation/{sample}/{sample}.junctionSaturation_plot.pdf", sample=ordered_sample_list ),
        expand( "analysis/bam2bw/{sample}/{sample}.bw", sample=ordered_sample_list ),
        expand("analysis/diffexp/{comparison}/{comparison}.deseq.csv", comparison=comparisons),
        expand("analysis/diffexp/{comparison}/{comparison}_volcano.pdf", comparison=comparisons),
        de_summary_out_png,
        expand("analysis/snp/{sample}/{sample}.snp.hla.txt", sample=ordered_sample_list),
        "analysis/snp/snp_corr.hla.txt",
        "analysis/plots/sampleSNPcorr_plot.hla.png",
        #run_snp_genome(wildcards=ordered_sample_list),
        run_snp_genome,
        fusion_output,
        insert_size_output,
        rRNA_metrics,
        expand("analysis/diffexp/{comparison}/{comparison}.goterm.done", comparison=comparisons),
        expand("analysis/diffexp/{comparison}/{comparison}.kegg.done", comparison=comparisons),
        expand("analysis/diffexp/{comparison}/deseq_limma_fc_corr.png", comparison=comparisons),
        "report.html"
    message: "Compiling all output"
        
#["analysis/plots/correlation_plot.pdf", "analysis/plots/correlation_table.csv", "analysis/plots/upvenn_plot.pdf", "analysis/plots/downvenn_plot.pdf"] if len(comparisons) >= 2 else []


rule generate_report:
    input:
        "analysis/RSeQC/read_distrib/read_distrib.png","analysis/RSeQC/gene_body_cvg/geneBodyCoverage.heatMap.png",
        rRNA_metrics, "analysis/plots/pca_plot.pdf", "analysis/plots/heatmapSS_plot.pdf", "analysis/plots/heatmapSF_plot.pdf",
        expand("analysis/diffexp/{comparison}/{comparison}_volcano.pdf", comparison=comparisons),
        expand( "analysis/plots/sampleSNPcorr_plot.hla.png"),
        expand("analysis/diffexp/{comparison}/{comparison}.goterm.done", comparison=comparisons),
        expand("analysis/diffexp/{comparison}/{comparison}.kegg.done", comparison=comparisons),
        fusion_output,
        force_run_upon_meta_change = config['metasheet'],
        force_run_upon_config_change = config['config_file']
    output:
        "report.html"
    message: "Generating VIPER report"
    run:
        sphinx_str = get_sphinx_report(comparisons)
        report(sphinx_str, output[0], metadata="Molecular Biology Core Facilities, DFCI", **{'Copyrights:':"./viper/mbcf.jpg"})


rule run_STAR:
    input:
        get_fastq
    output:
        bam=protected("analysis/STAR/{sample}/{sample}.sorted.bam"),
        counts="analysis/STAR/{sample}/{sample}.counts.tab",
        log_file="analysis/STAR/{sample}/{sample}.Log.final.out"
    params:
        stranded=strand_command,
        gz_support=gz_command,
        prefix=lambda wildcards: "analysis/STAR/{sample}/{sample}".format(sample=wildcards.sample),
        readgroup=lambda wildcards: "ID:{sample} PL:illumina LB:{sample} SM:{sample}".format(sample=wildcards.sample)
    threads: 8
    message: "Running STAR Alignment on {wildcards.sample}"
    shell:
        "STAR --runMode alignReads --runThreadN {threads} --genomeDir {config[star_index]}"
	" --sjdbGTFfile {config[gtf_file]}"
        " --readFilesIn {input} {params.gz_support} --outFileNamePrefix {params.prefix}."
	"  --outSAMstrandField intronMotif"
        "  --outSAMmode Full --outSAMattributes All {params.stranded} --outSAMattrRGline {params.readgroup} --outSAMtype BAM SortedByCoordinate"
        "  --limitBAMsortRAM 45000000000 --quantMode GeneCounts"
        " && mv {params.prefix}.Aligned.sortedByCoord.out.bam {output.bam}"
        " && mv {params.prefix}.ReadsPerGene.out.tab {output.counts}"
        " && /usr/bin/samtools index {output.bam}"


rule generate_STAR_report:
    input:
        star_log_files=expand( "analysis/STAR/{sample}/{sample}.Log.final.out", sample=ordered_sample_list ),
        star_gene_count_files=expand( "analysis/STAR/{sample}/{sample}.counts.tab", sample=ordered_sample_list ),
        force_run_upon_meta_change = config['metasheet'],
        force_run_upon_config_change = config['config_file']
    output:
        csv="analysis/STAR/STAR_Align_Report.csv",
        png="analysis/STAR/STAR_Align_Report.png",
        gene_counts="analysis/STAR/STAR_Gene_Counts.csv"
    message: "Generating STAR report"
    priority: 3
    run:
        log_files = " -l ".join( input.star_log_files )
        count_files = " -f ".join( input.star_gene_count_files )
        shell( "perl viper/scripts/STAR_reports.pl -l {log_files} 1>{output.csv}" )
        shell( "Rscript viper/scripts/map_stats.R {output.csv} {output.png}" )
        shell( "perl viper/scripts/raw_and_fpkm_count_matrix.pl -f {count_files} 1>{output.gene_counts}" )

rule run_cufflinks:
    input:
        "analysis/STAR/{sample}/{sample}.sorted.bam"
    output:
        protected("analysis/cufflinks/{sample}/{sample}.genes.fpkm_tracking")
    threads: 4
    message: "Running Cufflinks on {wildcards.sample}"
    params:
        library_command=cuff_command
    shell:
        "cufflinks -o analysis/cufflinks/{wildcards.sample} -p {threads} -G {config[gtf_file]} {params.library_command} {input}"
        " && mv analysis/cufflinks/{wildcards.sample}/genes.fpkm_tracking {output}"
        " && mv analysis/cufflinks/{wildcards.sample}/isoforms.fpkm_tracking analysis/cufflinks/{wildcards.sample}/{wildcards.sample}.isoforms.fpkm_tracking"

rule generate_cuff_matrix:
    input:
        cuff_gene_fpkms=expand( "analysis/cufflinks/{sample}/{sample}.genes.fpkm_tracking", sample=ordered_sample_list ),
        force_run_upon_meta_change = config['metasheet'],
        force_run_upon_config_change = config['config_file']
    output:
        "analysis/cufflinks/Cuff_Gene_Counts.csv"
    message: "Generating expression matrix using cufflinks counts"
    priority: 3
    run:
        fpkm_files= " -f ".join( input.cuff_gene_fpkms )
        shell( "perl viper/scripts/raw_and_fpkm_count_matrix.pl -c -f {fpkm_files} 1>{output}" )


rule run_STAR_fusion:
    input:
        bam="analysis/STAR/{sample}/{sample}.sorted.bam" #just to make sure STAR output is available before STAR_Fusion
    output:
        protected("analysis/STAR_Fusion/{sample}/{sample}.fusion_candidates.final")
    log:
        "analysis/STAR_Fusion/{sample}/{sample}.star_fusion.log"
    message: "Running STAR fusion on {wildcards.sample}"
    shell:
        "STAR-Fusion --chimeric_junction analysis/STAR/{wildcards.sample}/{wildcards.sample}.Chimeric.out.junction "
        "--genome_lib_dir {config[genome_lib_dir]} --output_dir analysis/STAR_Fusion/{wildcards.sample} >& {log}"
        " && mv analysis/STAR_Fusion/{wildcards.sample}/star-fusion.fusion_candidates.final {output}"
        " && mv analysis/STAR_Fusion/{wildcards.sample}/star-fusion.fusion_candidates.final.abridged"
        " analysis/STAR_Fusion/{wildcards.sample}/{wildcards.sample}.fusion_candidates.final.abridged"
        " && touch {output}" # For some sample, final.abridged is created but not .final file; temp hack before further investigate into this


rule run_STAR_fusion_report:
    input:
        sf_list = expand("analysis/STAR_Fusion/{sample}/{sample}.fusion_candidates.final.abridged", sample=ordered_sample_list),
        force_run_upon_meta_change = config['metasheet'],
        force_run_upon_config_change = config['config_file']
    output:
        csv="analysis/STAR_Fusion/STAR_Fusion_Report.csv",
        png="analysis/STAR_Fusion/STAR_Fusion_Report.png"
    message: "Generating STAR fusion report"
    shell:
        "python viper/scripts/STAR_Fusion_report.py -f {input.sf_list} 1>{output.csv} "
        "&& Rscript viper/scripts/STAR_Fusion_report.R {output.csv} {output.png}"

rule read_distrib_qc:
    input:
        "analysis/STAR/{sample}/{sample}.sorted.bam"
    output:
        protected("analysis/RSeQC/read_distrib/{sample}.txt")
    message: "Running RseQC read distribution on {wildcards.sample}"
    params: pypath="PYTHONPATH=%s" % python2_pythonpath
    shell:
        "{params.pypath} {config[python2]} {config[rseqc_path]}/read_distribution.py"
        " --input-file={input}"
        " --refgene={config[bed_file]} 1>{output}"

rule read_distrib_qc_matrix:
    input:
        read_distrib_files=expand( "analysis/RSeQC/read_distrib/{sample}.txt", sample=ordered_sample_list ),
        force_run_upon_meta_change = config['metasheet'],
        force_run_upon_config_change = config['config_file']
    output:
        matrix="analysis/RSeQC/read_distrib/read_distrib.matrix.tab",
        png="analysis/RSeQC/read_distrib/read_distrib.png"
    message: "Creating RseQC read distribution matrix"
    run:
        file_list_with_flag = " -f ".join( input.read_distrib_files )
        shell( "perl viper/scripts/read_distrib_matrix.pl -f {file_list_with_flag} 1>{output.matrix}" )
        shell( "Rscript viper/scripts/read_distrib.R {output.matrix} {output.png}" )

rule down_sample:
    input:
        "analysis/STAR/{sample}/{sample}.sorted.bam"
    output:
        "analysis/RSeQC/gene_body_cvg/downsample/{sample}.downsample.sorted.bam"
    message: "Running RseQC downsample gene body coverage for {wildcards.sample}"
    shell:
        "{config[picard_path]} DownsampleSam INPUT={input} OUTPUT={output}"
        " PROBABILITY=0.1"
        " && samtools index {input}"

rule gene_body_cvg_qc:
    input:
        "analysis/STAR/{sample}/{sample}.sorted.bam"
    output:
        protected("analysis/RSeQC/gene_body_cvg/{sample}/{sample}.geneBodyCoverage.curves.png"),
        protected("analysis/RSeQC/gene_body_cvg/{sample}/{sample}.geneBodyCoverage.r")
    message: "Creating gene body coverage curves"
    params: pypath="PYTHONPATH=%s" % python2_pythonpath
    shell:
        "{params.pypath} {config[python2]} {config[rseqc_path]}/geneBody_coverage.py -i {input} -r {config[bed_file]}"
        " -f png -o analysis/RSeQC/gene_body_cvg/{wildcards.sample}/{wildcards.sample}"


rule plot_gene_body_cvg:
    input:
        samples_list=expand("analysis/RSeQC/gene_body_cvg/{sample}/{sample}.geneBodyCoverage.r", sample=ordered_sample_list ),
        force_run_upon_meta_change = config['metasheet'],
        force_run_upon_config_change = config['config_file']
    output:
        rscript="analysis/RSeQC/gene_body_cvg/geneBodyCoverage.r",
        png="analysis/RSeQC/gene_body_cvg/geneBodyCoverage.heatMap.png",
        png_curves="analysis/RSeQC/gene_body_cvg/geneBodyCoverage.curves.png"
    message: "Plotting gene body coverage"
    shell:
        "perl viper/scripts/plot_gene_body_cvg.pl --rfile {output.rscript} --png {output.png} --curves_png {output.png_curves}"
        " {input.samples_list} && Rscript {output.rscript}"

rule junction_saturation:
    input:
        "analysis/STAR/{sample}/{sample}.sorted.bam"
    output:
        protected("analysis/RSeQC/junction_saturation/{sample}/{sample}.junctionSaturation_plot.pdf")
    message: "Determining junction saturation for {wildcards.sample}"
    params: pypath="PYTHONPATH=%s" % python2_pythonpath
    shell:
        "{params.pypath} {config[python2]} {config[rseqc_path]}/junction_saturation.py -i {input} -r {config[bed_file]}"
        " -o analysis/RSeQC/junction_saturation/{wildcards.sample}/{wildcards.sample}"


rule collect_insert_size:
    input:
        "analysis/STAR/{sample}/{sample}.sorted.bam"
    output:
        protected("analysis/RSeQC/insert_size/{sample}/{sample}.histogram.pdf")
    message: "Collecting insert size for {wildcards.sample}"
    shell:
        "{config[picard_path]} CollectInsertSizeMetrics"
        " H={output} I={input} O=analysis/RSeQC/insert_size/{wildcards.sample}/{wildcards.sample} R={config[ref_fasta]}"


rule run_rRNA_STAR:
    input:
        get_fastq
    output:
        bam=protected("analysis/STAR_rRNA/{sample}/{sample}.sorted.bam"),
        log_file="analysis/STAR_rRNA/{sample}/{sample}.Log.final.out"
    params:
        stranded=rRNA_strand_command,
        prefix=lambda wildcards: "analysis/STAR_rRNA/{sample}/{sample}".format(sample=wildcards.sample),
        readgroup=lambda wildcards: "ID:{sample} PL:illumina LB:{sample} SM:{sample}".format(sample=wildcards.sample)
    threads: 8
    message: "Running rRNA STAR for {wildcards.sample}"
    shell:
        "STAR --runMode alignReads --runThreadN {threads} --genomeDir {config[star_rRNA_index]}"
        " --readFilesIn {input} --readFilesCommand zcat --outFileNamePrefix {params.prefix}."
        "  --outSAMmode Full --outSAMattributes All {params.stranded} --outSAMattrRGline {params.readgroup} --outSAMtype BAM SortedByCoordinate"
        "  --limitBAMsortRAM 45000000000"
        " && mv {params.prefix}.Aligned.sortedByCoord.out.bam {output.bam}"
        " && samtools index {output.bam}"


rule generate_rRNA_STAR_report:
    input:
        star_log_files=expand( "analysis/STAR_rRNA/{sample}/{sample}.Log.final.out", sample=ordered_sample_list ),
        force_run_upon_meta_change = config['metasheet'],
        force_run_upon_config_change = config['config_file']
    output:
        csv="analysis/STAR_rRNA/STAR_rRNA_Align_Report.csv",
        png="analysis/STAR_rRNA/STAR_rRNA_Align_Report.png"
    message: "Generating STAR rRNA report"
    run:
        log_files = " -l ".join( input.star_log_files )
        shell( "perl viper/scripts/STAR_reports.pl -l {log_files} 1>{output.csv}" )
        shell( "Rscript viper/scripts/map_stats_rRNA.R {output.csv} {output.png}" )

rule get_chrom_size:
    output:
        "analysis/bam2bw/" + config['reference'] + ".Chromsizes.txt"
    params:
        config['reference']
    message: "Fetching chromosome sizes"
    shell:
        "fetchChromSizes {params} 1>{output}"
        " && if [ -e /zfs/cores/mbcf/mbcf-storage/devel/umv/ref_files/ERCC/input/ERCC92.chromInfo ]; then cat /zfs/cores/mbcf/mbcf-storage/devel/umv/ref_files/ERCC/input/ERCC92.chromInfo 1>>{output}; fi"


rule bam_to_bigwig:
    input:
        bam="analysis/STAR/{sample}/{sample}.sorted.bam",
        chrom_size="analysis/bam2bw/" + config['reference'] + ".Chromsizes.txt"
    output:
        protected("analysis/bam2bw/{sample}/{sample}.bw")
    params:
        "analysis/bam2bw/{sample}/{sample}"
    message: "Converting {wildcards.sample} bam to bigwig"
    shell:
        "bedtools genomecov -bg -split -ibam {input.bam} -g {input.chrom_size} 1> {params}.bg"
        " && bedSort {params}.bg {params}.sorted.bg"
        " && bedGraphToBigWig {params}.sorted.bg {input.chrom_size} {output}"

if config["batch_effect_removal"] == "true":
    rule batch_effect_removal_cufflinks:
        input:
            cuffmat = "analysis/cufflinks/Cuff_Gene_Counts.csv",
            annotFile = config["metasheet"]
        output:
            cuffcsvoutput="analysis/cufflinks/batch_corrected_Cuff_Gene_Counts.csv",
            cuffpdfoutput="analysis/cufflinks/cuff_combat_qc.pdf"
        params:
            batch_column="batch",
            datatype = "cufflinks"
        message: "Removing batch effect from Cufflinks Gene Count matrix, if errors, check metasheet for batches, refer to README for specifics"
        priority: 2
        shell:
            """
            Rscript viper/scripts/batch_effect_removal.R {input.cuffmat} {input.annotFile} {params.batch_column} {params.datatype} {output.cuffcsvoutput} {output.cuffpdfoutput}
            mv {input.cuffmat} analysis/cufflinks/without_batch_correction_Cuff_Gene_Counts.csv
            """
            
if config["batch_effect_removal"] == "true":
    rule batch_effect_removal_star:
        input:
            starmat = "analysis/STAR/STAR_Gene_Counts.csv",
            annotFile = config["metasheet"]
        output:
            starcsvoutput="analysis/STAR/batch_corrected_STAR_Gene_Counts.csv",
            starpdfoutput="analysis/STAR/star_combat_qc.pdf"
        params:
            batch_column="batch",
            datatype = "star"
        message: "Removing batch effect from STAR Gene Count matrix, if errors, check metasheet for batches, refer to README for specifics"
        priority: 2
        shell:
            """
            Rscript viper/scripts/batch_effect_removal.R {input.starmat} {input.annotFile} {params.batch_column} {params.datatype} {output.starcsvoutput} {output.starpdfoutput}
            mv {input.starmat} analysis/STAR/without_batch_correction_STAR_Gene_Counts.csv
            """
            
rule pca_plot:
    input:
        #rpkmFile="analysis/cufflinks/Cuff_Gene_Counts.csv",
        rpkmFile = get_cuff_counts(config),
        annotFile=config['metasheet'],
        force_run_upon_config_change = config['config_file']
    output:
        expand("analysis/plots/images/pca_plot_{metacol}.png", metacol=metacols),
        pca_plot_out="analysis/plots/pca_plot.pdf"
    params:
        RPKM_threshold = config["RPKM_threshold"],
        min_num_samples_expressing_at_threshold = config["min_num_samples_expressing_at_threshold"],
        filter_mirna = config["filter_mirna"],
        SSnumgenes = config["SSnumgenes"]
    message: "Generating PCA plots"
#    shell:
#        "scripts/pca_plot.R"
#    run:
#        shell("Rscript viper/scripts/pca_plot_new.R {input.rpkmFile} {input.annotFile} {params.RPKM_threshold} {params.min_num_samples_expressing_at_threshold} {params.filter_mirna} {params.SSnumgenes} {output.pca_plot_out}")
    run:
        shell("Rscript viper/scripts/pca_plot.R {input.rpkmFile} {input.annotFile} {params.RPKM_threshold} {params.min_num_samples_expressing_at_threshold} {params.filter_mirna} {params.SSnumgenes} {output.pca_plot_out}")


rule heatmapSS_plot:
    input:
        #rpkmFile="analysis/cufflinks/Cuff_Gene_Counts.csv",
        rpkmFile = get_cuff_counts(config),
        annotFile=config['metasheet'],
        force_run_upon_config_change = config['config_file']
    output:
        ss_plot_out="analysis/plots/heatmapSS_plot.pdf",
        ss_txt_out="analysis/plots/heatmapSS.txt"
    params:
        RPKM_threshold = config["RPKM_threshold"],
        min_num_samples_expressing_at_threshold = config["min_num_samples_expressing_at_threshold"],
        filter_mirna = config["filter_mirna"],
        SSnumgenes = config["SSnumgenes"]
    message: "Generating Sample-Sample Heatmap"
    run:
        shell("mkdir -p analysis/plots/images && Rscript viper/scripts/heatmapSS_plot.R {input.rpkmFile} {input.annotFile} {params.RPKM_threshold} {params.min_num_samples_expressing_at_threshold} {params.filter_mirna} {params.SSnumgenes} {output.ss_plot_out} {output.ss_txt_out}")

rule heatmapSF_plot:
    input:
        #rpkmFile="analysis/cufflinks/Cuff_Gene_Counts.csv",
        rpkmFile = get_cuff_counts(config),
        annotFile=config['metasheet'],
        force_run_upon_config_change = config['config_file']
    output:
        sf_plot_out="analysis/plots/heatmapSF_plot.pdf",
        sf_txt_out="analysis/plots/heatmapSF.txt"
    params:
        RPKM_threshold = config["RPKM_threshold"],
        min_num_samples_expressing_at_threshold = config["min_num_samples_expressing_at_threshold"],
        filter_mirna = config["filter_mirna"],
        SFnumgenes = config["SFnumgenes"],
        num_kmeans_clust = config["num_kmeans_clust"]
    message: "Generating Sample-Feature heatmap"
    run:
        shell("mkdir -p analysis/plots/images && Rscript viper/scripts/heatmapSF_plot.R {input.rpkmFile} {input.annotFile} {params.RPKM_threshold} {params.min_num_samples_expressing_at_threshold} {params.filter_mirna} {params.SFnumgenes} {params.num_kmeans_clust} {output.sf_plot_out} {output.sf_txt_out}")

#PART 2.2- diffexp w/ DEseq
#based on tosh's coppRhead/Snakefile

## Extract comparisons from the metadata file and perform gfold diff
def get_column(comparison):
    return metadata["comp_{}".format(comparison)]

def get_comparison(name, group):
    comp = get_column(name)
    return metadata[comp == group].index

def get_samples(wildcards):
    comp = get_column(wildcards.comparison)
    return comp.dropna().index

## Perform Limma and DEseq on comparisons
rule limma_and_deseq:
    input:
        #counts = "analysis/STAR/STAR_Gene_Counts.csv"
        counts = get_STAR_counts(config)
    output:
        limma = "analysis/diffexp/{comparison}/{comparison}.limma.csv",
        deseq = "analysis/diffexp/{comparison}/{comparison}.deseq.csv",
        deseqSum = "analysis/diffexp/{comparison}/{comparison}.deseq.sum.csv",
        #annotations
        limma_annot = "analysis/diffexp/{comparison}/{comparison}.limma.annot.csv",
        deseq_annot = "analysis/diffexp/{comparison}/{comparison}.deseq.annot.csv",
    params:
        s1=lambda wildcards: ",".join(get_comparison(wildcards.comparison, 1)),
        s2=lambda wildcards: ",".join(get_comparison(wildcards.comparison, 2)),
        gene_annotation = config['gene_annotation']
    message: "Running differential expression analysis using limma and deseq for {wildcards.comparison}"
#    script:
#        "scripts/DEseq.R"

    run:
        shell("Rscript viper/scripts/DEseq.R \"{input.counts}\" \"{params.s1}\" \"{params.s2}\" {output.limma} {output.deseq} {output.limma_annot} {output.deseq_annot} {output.deseqSum} {params.gene_annotation}")

rule deseq_limma_fc_plot:
    input:
        deseq = "analysis/diffexp/{comparison}/{comparison}.deseq.csv",
        limma = "analysis/diffexp/{comparison}/{comparison}.limma.csv"
    output:
        out_csv = "analysis/diffexp/{comparison}/deseq_limma_fc_corr.csv",
        out_png = "analysis/diffexp/{comparison}/deseq_limma_fc_corr.png"
    shell:
        "Rscript viper/scripts/deseq_limma_fc_corr.R {input.deseq} {input.limma} {output.out_csv} {output.out_png}"


rule fetch_DE_gene_list:
    input:
        deseq_file_list=expand("analysis/diffexp/{comparison}/{comparison}.deseq.csv",comparison=comparisons),
        force_run_upon_meta_change = config['metasheet'],
        force_run_upon_config_change = config['config_file']
    output:
        csv="analysis/diffexp/de_summary.csv",
        png="analysis/diffexp/de_summary.png"
    message: "Creating Differential Expression summary"
    run:
        deseq_file_string = ' -f '.join(input.deseq_file_list)
        shell("perl viper/scripts/get_de_summary_table.pl -f {deseq_file_string} 1>{output.csv}")
        shell("Rscript viper/scripts/de_summary.R {output.csv} {output.png}")

#Generate volcano plots for each comparison
rule volcano_plot:
    input:
        deseq = "analysis/diffexp/{comparison}/{comparison}.deseq.csv",
        force_run_upon_meta_change = config['metasheet'],
        force_run_upon_config_change = config['config_file']
    output:
        plot = "analysis/diffexp/{comparison}/{comparison}_volcano.pdf",
        png = "analysis/plots/images/{comparison}_volcano.png"
    message: "Creating volcano plots for Differential Expressions for {wildcards.comparison}"
    run:
        shell("Rscript viper/scripts/volcano_plot.R {input.deseq} {output.plot} {output.png}")

rule goterm_analysis:
    input:
        deseq = "analysis/diffexp/{comparison}/{comparison}.deseq.csv",
        force_run_upon_meta_change = config['metasheet'],
        force_run_upon_config_change = config['config_file']
    output:
        out_file = "analysis/diffexp/{comparison}/{comparison}.goterm.done"
    params:
        csv = "analysis/diffexp/{comparison}/{comparison}.goterm.csv",
        plot = "analysis/diffexp/{comparison}/{comparison}.goterm.pdf",
        png = "analysis/plots/images/{comparison}_goterm.png",
        gotermadjpvalcutoff = config["goterm_adjpval_cutoff"],
        numgoterms = config["numgoterms"],
        reference = config["reference"]
    message: "Creating Goterm Analysis plots for Differential Expressions for {wildcards.comparison}"
    run:
        shell("Rscript viper/scripts/goterm_analysis.R {input.deseq} {params.gotermadjpvalcutoff} {params.numgoterms} {params.reference} {params.csv} {params.plot} {params.png} ")
        shell("touch {output.out_file}")

rule kegg_analysis:
    input:
        deseq = "analysis/diffexp/{comparison}/{comparison}.deseq.csv",
        force_run_upon_meta_change = config['metasheet'],
        force_run_upon_config_change = config['config_file']
    output:
        out_file = "analysis/diffexp/{comparison}/{comparison}.kegg.done"
    params:
        keggpvalcutoff = config["kegg_pval_cutoff"],
        numkeggpathways = config["numkeggpathways"],
        kegg_table_up = "analysis/diffexp/{comparison}/{comparison}.kegg.up.csv",
        kegg_table_down = "analysis/diffexp/{comparison}/{comparison}.kegg.down.csv",
        keggsummary_pdf = "analysis/diffexp/{comparison}/{comparison}.keggsummary.pdf",
        keggsummary_png = "analysis/plots/images/{comparison}.keggsummary.png",
        gsea_table = "analysis/diffexp/{comparison}/{comparison}.gsea.csv",
        gsea_pdf = "analysis/diffexp/{comparison}/{comparison}.gsea.pdf",
        kegg_dir = "analysis/diffexp/{comparison}/kegg_pathways/",
        reference = "hg19",
        temp_dir = "analysis/diffexp/{comparison}/temp/"
    message: "Creating Kegg Pathway Analysis for Differential Expressions for {wildcards.comparison}"
    run:
        shell( "mkdir {params.temp_dir} ")
        shell("Rscript viper/scripts/kegg_pathway.R {input.deseq} {params.keggpvalcutoff} {params.numkeggpathways} {params.kegg_dir} {params.reference} {params.temp_dir} {params.kegg_table_up} {params.kegg_table_down} {params.keggsummary_pdf} {params.keggsummary_png} {params.gsea_table} {params.gsea_pdf} ")
        shell("touch {output.out_file}")
        shell( " rm -rf {params.temp_dir} ")

#call snps from the samples
#NOTE: lots of duplicated code below!--ONE SET for chr6 (default) and another
#for genome-wide
#------------------------------------------------------------------------------
# snp calling for chr6 (default)
#------------------------------------------------------------------------------
rule call_snps_hla:
    input:
        bam="analysis/STAR/{sample}/{sample}.sorted.bam",
        ref_fa=config["ref_fasta"],
    output:
        protected("analysis/snp/{sample}/{sample}.snp.hla.txt")
    params:
        varscan_path = config["varscan_path"],
        region = _HLA_regions[config['reference']]
    message: "Running varscan for snp analysis for ch6 fingerprint region"
    shell:
        "samtools mpileup -r \"{params.region}\" -f {input.ref_fa} {input.bam} | awk \'$4 != 0\' | "
        "{params.varscan_path} pileup2snp - --min-coverage 20 --min-reads2 4 > {output}"

#calculate sample snps correlation using all samples
rule sample_snps_corr_hla:
    input:
        snps = lambda wildcards: expand("analysis/snp/{sample}/{sample}.snp.hla.txt", sample=ordered_sample_list),
        force_run_upon_meta_change = config['metasheet'],
        force_run_upon_config_change = config['config_file']
    output:
        "analysis/snp/snp_corr.hla.txt"
    message: "Running snp correlations for HLA fingerprint region"
    run:
        snps = " ".join(input.snps)
        shell("{config[python2]} viper/scripts/sampleSNPcorr.py {snps}> {output}")

rule snps_corr_plot_hla:
    input:
        snp_corr="analysis/snp/snp_corr.hla.txt",
        annotFile=config['metasheet'],
        force_run_upon_config_change = config['config_file']
    output:
        snp_plot_out="analysis/plots/sampleSNPcorr_plot.hla.png",
        snp_plot_pdf="analysis/plots/sampleSNPcorr_plot.hla.pdf"
    message: "Running snp analysis for HLA fingerprint region"
    run:
        shell("Rscript viper/scripts/sampleSNPcorr_plot.R {input.snp_corr} {input.annotFile} {output.snp_plot_out} {output.snp_plot_pdf}")

#------------------------------------------------------------------------------
# snp calling GENOME wide (hidden config.yaml flag- 'snp_scan_genome:True'
#------------------------------------------------------------------------------

rule call_snps_genome:
    input:
        bam="analysis/STAR/{sample}/{sample}.sorted.bam",
        ref_fa=config["ref_fasta"],
    output:
        protected("analysis/snp/{sample}/{sample}.snp.genome.vcf")
    params:
        varscan_path=config["varscan_path"]
    message: "Running varscan for snp analysis genome wide"
    shell:
        "samtools mpileup -f {input.ref_fa} {input.bam} | awk \'$4 != 0\' | "
        "{params.varscan_path} mpileup2snp - --min-coverage 20 --min-reads2 4 --output-vcf > {output}"

#DROPPED--we only do snps corr on hla regions
# rule sample_snps_corr_genome:
#     input:
#         snps = lambda wildcards: expand("analysis/snp/{sample}/{sample}.snp.genome.txt", sample=ordered_sample_list),
#         force_run_upon_meta_change = config['metasheet'],
#         force_run_upon_config_change = config['config_file']
#     output:
#         "analysis/snp/snp_corr.genome.txt"
#     message: "Running snp analysis genome wide"
#     run:
#         snps = " ".join(input.snps)
#         shell("{config[python2]} viper/scripts/sampleSNPcorr.py {snps}> {output}")

# rule snps_corr_plot_genome:
#     input:
#         snp_corr="analysis/snp/snp_corr.genome.txt",
#         annotFile=config['metasheet'],
#         force_run_upon_config_change = config['config_file']
#     output:
#         snp_plot_out="analysis/plots/sampleSNPcorr_plot.genome.png",
#         snp_plot_pdf="analysis/plots/sampleSNPcorr_plot.genome.pdf"
#     message: "Creating snp plot genome wide"
#     run:
#         shell("Rscript viper/scripts/sampleSNPcorr_plot.R {input.snp_corr} {input.annotFile} {output.snp_plot_out} {output.snp_plot_pdf}")




