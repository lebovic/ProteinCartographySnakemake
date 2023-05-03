import os
from pathlib import Path

# Get protein IDs from fasta files in input directory
# In the future, have this specified by command line argument or config file
# In the future, also accept Uniprot accession numbers, which will be auto-queried and downloaded
input_dir = Path('input_minitest/')

# put most things into the output directory
output_dir = Path('output_minitest/')

# these directories fall within the output directory
blastresults_dir = Path('blastresults/')
foldseekresults_dir = Path('foldseekresults/')
foldseekclustering_dir = Path('foldseekclustering/')

PROTID = [os.path.basename(i).split('.fasta')[0] for i in os.listdir(input_dir) if '.fasta' in i]

######################################

rule all:
    input:
        output_dir / foldseekclustering_dir / "alphafold_querylist.txt",
        output_dir / 'dummy.txt'
# technically the alphafold_querylist.txt file doesn't need to be in rule all to be generated
# but it needs to be there in order for us to build a more complete visual of the rule graph

###########################################
## make .pdb files using gget alphafold
###########################################

# Ignore this for now, I'm having hardware problems getting gget to work
# It seems to be an Apple M1-specific problem

rule make_pdb:
    '''
    Use gget alphafold to generate a pdb from a fasta file.
    '''
    input:
        cds = input_dir / "{protid}.fasta"
    output:
        pdb = input_dir / "{protid}.pdb"
    shell:
        '''
        python utils/esmfold_apiquery.py -i {input.cds}
        '''

###########################################
## perform blastp to full database using nr
###########################################

rule run_blast:
    '''
    Using files located in the "inputs/" folder, perform BLAST using the web API.
    '''
    input:
        cds = input_dir / "{protid}.fasta"
    output:
        results = output_dir / blastresults_dir / "{protid}.blastresults.tsv"
    shell:
        '''
        blastp -db nr -query {input.cds} -out {output.results} -remote -max_target_seqs 50000 -outfmt 6
        '''

rule extract_blasthits:
    '''
    Using blast results files, generate lists of RefSeq ids for ID mapping.
    '''
    input:
        blastresults = output_dir / blastresults_dir / "{protid}.blastresults.tsv"
    output:
        refseqhits = output_dir / blastresults_dir / "{protid}.blasthits.refseq.txt"
    shell:
        '''
        python utils/extract_blasthits.py -i {input.blastresults} -o {output.refseqhits}
        '''

rule map_refseqids:
    '''
    Using List of RefSeq IDs, query the Uniprot ID mapping tool using bioservices UniProt.
    Returns a list of UniProt IDs.
    '''
    input:
        refseqhits = output_dir / blastresults_dir / "{protid}.blasthits.refseq.txt"
    output:
        uniprothits = output_dir / blastresults_dir / "{protid}.blasthits.uniprot.txt"
    shell:
        '''
        python utils/map_refseqids.py -i {input.refseqhits} -o {output.uniprothits}
        '''

######################################
## perform Foldseek using web API
######################################

# Note: this returns a limited number of hits; up to 1000 per database

rule run_foldseek:
    '''
    Runs Foldseek using a query to the web API using a custom Python script.
    The script accepts an input file ending in '.pdb' and returns an output file ending in '.tar.gz'.
    The script also accepts a `--mode` flag of either '3diaa' (default) or 'tmalign' and choice of databases.
    '''
    input:
        cds = input_dir / "{protid}.pdb"
    output:
        results = output_dir / foldseekresults_dir / "{protid}.fsresults.tar.gz"
    shell:
        '''
        python utils/foldseek_apiquery.py -i {input.cds} -o {output.results}
        '''

rule unpack_fsresults:
    '''
    Untars and unzips files into a directory for each protid.
    '''
    input:
        targz = output_dir / foldseekresults_dir / "{protid}.fsresults.tar.gz"
    output:
        unpacked = directory(output_dir / foldseekresults_dir / "{protid}/")
    shell:
        '''
        mkdir {output.unpacked}
        tar -xvf {input.targz} -C {output.unpacked}
        '''

rule extract_foldseekhits:
    '''
    Using Foldseek results directory, generate lists of Uniprot ids for mapping to Uniprot and pulling down PDB files.
    '''
    input:
        foldseekresults = output_dir / foldseekresults_dir / "{protid}/"
    output:
        foldseekhits = output_dir / foldseekresults_dir / "{protid}.foldseekhits.txt"
    shell:
        '''
        python utils/extract_foldseekhits.py -i {input.foldseekresults} -o {output.foldseekhits}
        '''

#####################################################################
## aggregate all hits, download metadata, download structure files
#####################################################################

rule aggregate_lists:
    '''
    Take all Uniprot ID lists and make them one big ID list, removing duplicates.
    '''
    input:
        expand(output_dir / foldseekresults_dir / "{protid}.foldseekhits.txt", protid = PROTID), 
        expand(output_dir / blastresults_dir / "{protid}.blasthits.uniprot.txt", protid = PROTID)
    output:
        jointlist = output_dir / foldseekclustering_dir / "alphafold_querylist.txt"
    shell:
        '''
        python utils/aggregate_lists.py -i {input} -o {output.jointlist}
        '''

checkpoint create_alphafold_wildcard:
    '''
    Create dummy files to make Snakemake detect a wildcard
    '''
    input:
        jointlist = output_dir / foldseekclustering_dir / "alphafold_querylist.txt"
    output: directory(os.path.join(output_dir, "alphafold_dummy/"))
    shell:
        '''
        python utils/make_dummies.py -i {input.jointlist} -o {output}
        '''
    
rule download_pdbs:
    '''
    Use a checkpoint to parse all of the items in the output.jointlist file from aggregate lists and download all the PDBs.
    Make sure to copy the user-input PDBs into the downloads directory
    '''
    input:
        output_dir / "alphafold_dummy/{acc}.txt"
    output:
        output_dir / foldseekclustering_dir / "{acc}.pdb"
    params:
        outdir = output_dir / foldseekclustering_dir
    shell:
        '''
        python utils/fetch_accession.py -a {wildcards.acc} -o {params.outdir} -f pdb
        '''
        
def checkpoint_create_alphafold_wildcard(wildcards):
    # expand checkpoint to get acc values
    checkpoint_output = checkpoints.create_alphafold_wildcard.get(**wildcards).output[0]
    
    # trawls the checkpoint_output file for .txt files
    # and generates expected .pdb file names for foldseekclustering_dir
    file_names = expand(output_dir / foldseekclustering_dir / "{acc}.pdb",
                        acc = glob_wildcards(os.path.join(checkpoint_output, "{acc}.txt")).acc)
    return file_names

rule dummy:
    '''
    Temporary rule for testing, touches empty file and stops.
    Used to make sure that the checkpoint function above is evaluated and to make rule all tidier.
    This will be changed in the future to a rule that actually does something.
    '''
    input: checkpoint_create_alphafold_wildcard
    output: output_dir / 'dummy.txt'
    shell:
        '''
        touch {output}
        '''
    
# rule get_uniprot_metadata:
#     '''
#     Use the output.jointlist file to query Uniprot and download all metadata as a big ol' TSV.
#     '''
#     ### I am unwritten... ###

# #####################################################################
# ## clustering and dimensionality reduction
# #####################################################################
    
# rule foldseek_cluster:
#     '''
#     Run Foldseek clustering on all the PDBs
#     '''
#     ### I am unwritten... ###

# rule dim_reduction:
#     '''
#     Perform dimensionality reduction, saving as an embedding matrix and a TSV
#     Write a set of functions to return Dataframes for interactive compute
#     Write helper functions to save the dataframes only called by main()
#     '''
#     ### I am unwritten... ###

# #####################################################################
# ## aggregate features into a big TSV and make a nice plot
# #####################################################################    

# rule aggregate_features:
#     '''
#     Aggregate all TSV features provided by user in some specific directory, making one big TSV
#     Will need to handle filling NAs properly for each column
#     '''
#     ### I am unwritten... ###
    
# rule make_scatter:
#     '''
#     Generate interactive scatter plot HTML programmatically based on user-input parameters
#     Takes the TSV from rule aggregate_features and select default columns
#     User should be able to call this module and pass their own functions to parse particular TSV columns
#     Should have means to set a palette for each individual plot type, maybe as JSON?
#     '''
#     ### I am unwritten... ###
