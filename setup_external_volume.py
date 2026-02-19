from snowflake_runner import SnowflakeRunner
import sys

def setup_volume():
    # Placeholder ARN for initial creation
    role_arn = "arn:aws:iam::641870614194:role/SnowflakeIcebergRole"
    bucket_name = "iceberg-general-bucket-0123456"
    
    create_sql = f"""
    CREATE OR REPLACE EXTERNAL VOLUME iceberg_external_vol
    STORAGE_LOCATIONS =
    (
        (
            NAME = 'iceberg-s3-loc'
            STORAGE_PROVIDER = 'S3'
            STORAGE_BASE_URL = 's3://{bucket_name}/iceberg-nav/'
            STORAGE_AWS_ROLE_ARN = '{role_arn}'
         )
    );
    """
    
    with SnowflakeRunner() as sf:
        print("Creating External Volume...")
        sf.query(create_sql)
        
        print("\nRetrieving Snowflake IAM details...")
        # DESC command returns the properties we need to give to the user
        results = sf.query("DESC EXTERNAL VOLUME iceberg_external_vol", silent=True)
        
        # Parse the output for the key fields
        # DESC returns rows with [property, property_type, property_value, ...]
        print("\n--- SNOWFLAKE IAM DETAILS ---")
        for row in results:
            print(row)
        print("--- END DETAILS ---\n")

if __name__ == "__main__":
    setup_volume()
